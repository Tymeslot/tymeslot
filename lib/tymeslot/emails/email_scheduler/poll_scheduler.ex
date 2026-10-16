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

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Jobs
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Workers.EmailWorker

  require Logger

  # 10 years in seconds — dedupe across arbitrarily long lead times.
  @unique_period 315_360_000
  # A host who wants to hear about new votes gets at most one update per
  # quarter hour, covering every vote cast in it.
  @vote_digest_delay_seconds 15 * 60

  @doc """
  Schedules a poll's reminders (`PollSchema.reminders/1`) and the
  deadline-passed host nudge.

  A reminder whose send time has already passed is skipped. A poll without a
  deadline schedules nothing. Each job carries the deadline it was scheduled
  for and is unique for it, so a job sent for an earlier deadline neither
  blocks one for a new deadline nor goes out against it.
  """
  @spec schedule_deadline_jobs(map()) :: :ok
  def schedule_deadline_jobs(%{deadline_at: nil}), do: :ok

  def schedule_deadline_jobs(poll) do
    poll |> PollSchema.reminders() |> Enum.each(&maybe_schedule_reminder(poll, &1))
    schedule_deadline_nudge(poll)
    :ok
  end

  @doc """
  Replaces a poll's pending reminders and deadline-passed nudge after its
  deadline or reminders changed. The vote updates and the "everyone has voted"
  nudge are left as they are.
  """
  @spec reschedule_deadline_jobs(map()) :: :ok
  def reschedule_deadline_jobs(poll) do
    Jobs.delete_poll_jobs_matching(poll.id, EmailWorker, %{
      "action" => "send_poll_deadline_reminders"
    })

    Jobs.delete_poll_jobs_matching(poll.id, EmailWorker, %{
      "action" => "send_poll_host_nudge",
      "variant" => "deadline_passed"
    })

    schedule_deadline_jobs(poll)
  end

  @doc "The deadline as job args carry it, to tell a stale job from a current one."
  @spec deadline_arg(DateTime.t()) :: String.t()
  def deadline_arg(%DateTime{} = deadline_at), do: DateTime.to_iso8601(deadline_at)

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

  @doc """
  Tells everyone who has already voted that `slots` were added to the poll.
  The job carries the new slots' ids, so the email names exactly those.
  """
  @spec schedule_new_times(map(), [map()]) :: :ok
  def schedule_new_times(poll, slots) do
    insert_job(
      %{
        "action" => "send_poll_new_times",
        "poll_id" => poll.id,
        "slot_ids" => Enum.map(slots, & &1.id)
      },
      []
    )
  end

  @doc """
  Tells every participant that the poll was cancelled. Scheduled after
  `cancel_deadline_jobs/1`, which would otherwise delete it.
  """
  @spec schedule_cancellation(map()) :: :ok
  def schedule_cancellation(poll) do
    insert_job(
      %{"action" => "send_poll_cancelled", "poll_id" => poll.id},
      unique: unique_opts([:action, :poll_id])
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

  defp maybe_schedule_reminder(poll, %{value: value, unit: unit}) do
    lead_seconds = ReminderUtils.reminder_interval_seconds(value, unit)
    reminder_at = DateTime.add(poll.deadline_at, -lead_seconds, :second)

    if DateTime.compare(reminder_at, DateTime.utc_now()) == :gt do
      insert_job(
        %{
          "action" => "send_poll_deadline_reminders",
          "poll_id" => poll.id,
          "deadline_at" => deadline_arg(poll.deadline_at),
          "reminder_value" => value,
          "reminder_unit" => unit
        },
        scheduled_at: reminder_at,
        unique: unique_opts([:action, :poll_id, :deadline_at, :reminder_value, :reminder_unit])
      )
    else
      :ok
    end
  end

  defp schedule_deadline_nudge(poll) do
    insert_job(
      %{
        "action" => "send_poll_host_nudge",
        "poll_id" => poll.id,
        "variant" => "deadline_passed",
        "deadline_at" => deadline_arg(poll.deadline_at)
      },
      scheduled_at: poll.deadline_at,
      unique: unique_opts([:action, :poll_id, :variant, :deadline_at])
    )
  end

  defp insert_job(args, opts) do
    opts = opts |> Keyword.put(:queue, :emails) |> Keyword.put(:priority, 2)

    case Oban.insert(EmailWorker.new(args, opts)) do
      {:ok, _job} ->
        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        # An identical job already exists; treat as scheduled.
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule poll email job",
          action: args["action"],
          poll_id: args["poll_id"],
          participant_id: args["participant_id"],
          error: Helpers.format_insert_error(reason)
        )

        :ok
    end
  end

  defp unique_opts(keys) do
    [period: @unique_period, fields: [:args, :queue], keys: keys]
  end
end
