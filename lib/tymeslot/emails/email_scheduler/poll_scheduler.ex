defmodule Tymeslot.Emails.EmailScheduler.PollScheduler do
  @moduledoc """
  Schedules poll emails via Oban: participants' voting links and receipts,
  deadline reminders and host nudges.

  Two jobs bracket a poll with a deadline: a reminder to unvoted participants 24
  hours before it closes, and a nudge to the host once it has passed. A separate
  immediate nudge fires the moment every participant has voted. Cancelling or
  confirming a poll deletes any of these that are still pending.

  A participant's link and receipt jobs carry only the participant's id: the
  link holds their token, which job args must not keep in the clear, so the
  handler reads it from the participant when it sends.
  """

  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Jobs
  alias Tymeslot.Workers.EmailWorker

  require Logger

  # 10 years in seconds — dedupe across arbitrarily long lead times.
  @unique_period 315_360_000
  # Reminders go out 24 hours before the deadline.
  @reminder_lead_seconds 86_400
  # A host who wants to hear about new votes gets at most one update per
  # quarter hour, covering every vote cast in it.
  @vote_digest_delay_seconds 15 * 60

  @doc """
  Schedules the deadline reminder and the deadline-passed host nudge for a poll.

  The reminder is skipped when the poll was created less than 24 hours before its
  deadline (its send time is already in the past). A poll without a deadline
  schedules nothing.
  """
  @spec schedule_deadline_jobs(map()) :: :ok
  def schedule_deadline_jobs(%{deadline_at: nil}), do: :ok

  def schedule_deadline_jobs(poll) do
    maybe_schedule_reminder(poll)
    schedule_deadline_nudge(poll)
    :ok
  end

  @doc """
  Schedules an immediate "everyone has voted" nudge to the host.

  Keyed so it fires at most once per poll, no matter how many times a participant
  re-submits their votes.
  """
  @spec schedule_all_voted_nudge(map()) :: :ok
  def schedule_all_voted_nudge(poll) do
    insert_job(
      %{"action" => "send_poll_host_nudge", "poll_id" => poll.id, "variant" => "all_voted"},
      unique: unique_opts([:action, :poll_id, :variant])
    )
  end

  @doc """
  Sends a participant their personal voting link now.

  Not deduplicated here: `Tymeslot.Polls.Voting` already allows one send per
  address in its resend window.
  """
  @spec schedule_participant_link(map()) :: :ok
  def schedule_participant_link(participant) do
    insert_job(
      %{"action" => "send_poll_participant_link", "participant_id" => participant.id},
      []
    )
  end

  @doc """
  Sends an invitee their invitation now. Keyed so it goes out once per
  participant; someone who loses it asks for their link on the voting page.
  """
  @spec schedule_invitation(map()) :: :ok
  def schedule_invitation(participant) do
    insert_job(
      %{"action" => "send_poll_invitation", "participant_id" => participant.id},
      unique: unique_opts([:action, :participant_id])
    )
  end

  @doc """
  Sends a participant the receipt for their first saved responses now. Keyed
  so it goes out once per participant.
  """
  @spec schedule_vote_receipt(map()) :: :ok
  def schedule_vote_receipt(participant) do
    insert_job(
      %{"action" => "send_poll_vote_receipt", "participant_id" => participant.id},
      unique: unique_opts([:action, :participant_id])
    )
  end

  @doc """
  Schedules the host's update on new votes for a quarter of an hour from now,
  unless one is already waiting: every vote cast until it runs joins that
  update. A vote cast while it is sending schedules the next one.
  """
  @spec schedule_vote_digest(map()) :: :ok
  def schedule_vote_digest(poll) do
    insert_job(
      %{"action" => "send_poll_vote_digest", "poll_id" => poll.id},
      scheduled_at: DateTime.add(DateTime.utc_now(), @vote_digest_delay_seconds, :second),
      unique: [
        period: :infinity,
        fields: [:args, :queue],
        keys: [:action, :poll_id],
        states: [:available, :scheduled, :retryable]
      ]
    )
  end

  @doc "Deletes any pending deadline reminder / host nudge jobs for a poll."
  @spec cancel_deadline_jobs(Ecto.UUID.t()) :: :ok
  def cancel_deadline_jobs(poll_id) do
    {deleted, _result} = Jobs.delete_poll_jobs(poll_id, EmailWorker)

    Logger.info("Cancelled pending poll email jobs",
      poll_id: poll_id,
      deleted_count: deleted
    )

    :ok
  end

  # --- Private helpers ---

  defp maybe_schedule_reminder(poll) do
    reminder_at = DateTime.add(poll.deadline_at, -@reminder_lead_seconds, :second)

    if DateTime.compare(reminder_at, DateTime.utc_now()) == :gt do
      insert_job(
        %{"action" => "send_poll_deadline_reminders", "poll_id" => poll.id},
        scheduled_at: reminder_at,
        unique: unique_opts([:action, :poll_id])
      )
    else
      :ok
    end
  end

  defp schedule_deadline_nudge(poll) do
    insert_job(
      %{"action" => "send_poll_host_nudge", "poll_id" => poll.id, "variant" => "deadline_passed"},
      scheduled_at: poll.deadline_at,
      unique: unique_opts([:action, :poll_id, :variant])
    )
  end

  # Best-effort: callers schedule these after their own commit, and a poll
  # without its reminder or nudge still works, so a failure is logged by
  # `Helpers.insert/2` and not returned.
  defp insert_job(args, opts) do
    opts = opts |> Keyword.put(:queue, :emails) |> Keyword.put(:priority, 2)

    _result =
      args
      |> EmailWorker.new(opts)
      |> Helpers.insert(poll_id: args["poll_id"], participant_id: args["participant_id"])

    :ok
  end

  defp unique_opts(keys) do
    [period: @unique_period, fields: [:args, :queue], keys: keys]
  end
end
