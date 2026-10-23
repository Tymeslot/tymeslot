defmodule Tymeslot.Emails.EmailScheduler.PollScheduler do
  @moduledoc """
  Schedules poll emails via Oban: participants' voting links and receipts,
  deadline reminders and host nudges.

  Two kinds of job bracket a poll with a deadline: reminders, at the lead
  times the host chose, to invitees who have not voted, and a nudge to the
  host once the deadline has passed. Reminders are scheduled only while the
  poll has invitees: on a poll shared only by its link, everyone who counts
  has voted already, since saving responses is what confirms them, so there
  is nobody to remind. A separate immediate nudge fires the moment every
  participant has voted. Cancelling or confirming a poll deletes any of
  these that are still pending.

  A participant's link and receipt jobs carry only the participant's id: the
  link holds their token, which job args must not keep in the clear, so the
  handler reads it from the participant when it sends.
  """

  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Jobs
  alias Tymeslot.MeetingTypes.Reminders
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Workers.EmailWorker

  require Logger

  # 10 years in seconds — dedupe across arbitrarily long lead times.
  @unique_period 315_360_000
  # A host who wants to hear about new votes gets at most one update per
  # quarter hour, covering every vote cast in it.
  @vote_digest_delay_seconds 15 * 60

  @doc """
  Schedules a poll's reminders (`PollSchema.reminders/1`), for a poll that
  has invitees.

  A reminder whose send time has already passed is skipped, and a poll
  without a deadline schedules none. Each job carries the deadline it was
  scheduled for and is unique for it, so scheduling again for the same
  deadline adds nothing, and a job sent for an earlier deadline neither
  blocks one for a new deadline nor goes out against it. A reminder still
  waiting from before jobs carried their deadline is replaced, not doubled.
  """
  @spec schedule_reminders(map()) :: :ok
  def schedule_reminders(%{deadline_at: nil}), do: :ok

  def schedule_reminders(poll) do
    {_deleted, _rows} = Jobs.delete_legacy_poll_reminders(poll.id, EmailWorker)
    poll |> PollSchema.reminders() |> Enum.each(&maybe_schedule_reminder(poll, &1))
  end

  @doc """
  Schedules the nudge telling the host their poll's deadline has passed.
  A poll without a deadline schedules none.
  """
  @spec schedule_deadline_nudge(map()) :: :ok
  def schedule_deadline_nudge(%{deadline_at: nil}), do: :ok

  def schedule_deadline_nudge(poll) do
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

  @doc """
  Replaces a poll's pending reminders and deadline-passed nudge after its
  deadline or reminders changed. The reminders are scheduled again only when
  `invited?`, that is, when the poll has invitees. The vote updates and the
  "everyone has voted" nudge are left as they are.
  """
  @spec reschedule_deadline_jobs(map(), boolean()) :: :ok
  def reschedule_deadline_jobs(poll, invited?) do
    :ok = cancel_reminders(poll.id)

    Jobs.delete_poll_jobs_matching(poll.id, EmailWorker, %{
      "action" => "send_poll_host_nudge",
      "variant" => "deadline_passed"
    })

    if invited?, do: schedule_reminders(poll)
    schedule_deadline_nudge(poll)
  end

  @doc "Deletes a poll's pending reminders, once it has no invitees left to remind."
  @spec cancel_reminders(Ecto.UUID.t()) :: :ok
  def cancel_reminders(poll_id) do
    Jobs.delete_poll_jobs_matching(poll_id, EmailWorker, %{
      "action" => "send_poll_deadline_reminders"
    })

    :ok
  end

  @doc "The deadline as job args carry it, to tell a stale job from a current one."
  @spec deadline_arg(DateTime.t()) :: String.t()
  def deadline_arg(%DateTime{} = deadline_at), do: DateTime.to_iso8601(deadline_at)

  @doc """
  Schedules an immediate "everyone has voted" nudge to the host.

  Keyed so it fires at most once per round, no matter how many times a
  participant re-submits their votes. `round` names the invitations the poll
  held (`PollParticipantQueries.invitation_round/1`): once the host invites
  more people and they all vote too, that is a new round and the host hears
  of it again.
  """
  @spec schedule_all_voted_nudge(map(), String.t()) :: :ok
  def schedule_all_voted_nudge(poll, round) when is_binary(round) do
    insert_job(
      %{
        "action" => "send_poll_host_nudge",
        "poll_id" => poll.id,
        "variant" => "all_voted",
        "round" => round
      },
      unique: unique_opts([:action, :poll_id, :variant, :round])
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
  participant; when it is lost the host sends it again with
  `schedule_invitation_again/1`.
  """
  @spec schedule_invitation(map()) :: :ok
  def schedule_invitation(participant) do
    insert_job(
      %{"action" => "send_poll_invitation", "participant_id" => participant.id},
      unique: unique_opts([:action, :participant_id])
    )
  end

  @doc """
  Sends an invitee their invitation again now, at the host's request.

  Not deduplicated here: the first invitation's key would swallow every
  resend, and `Tymeslot.Polls.Invitations.resend/2` already allows one send
  per participant in the resend window.
  """
  @spec schedule_invitation_again(map()) :: :ok
  def schedule_invitation_again(participant) do
    insert_job(
      %{"action" => "send_poll_invitation", "participant_id" => participant.id},
      []
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

  The job carries what the email needs: the poll's title, its host, and each
  participant's name, address, language and whether they voted. The host may then delete the
  poll straight after cancelling it, and the participants are still told.
  Its `user_id` also lets an account deletion clear it with the rest of the
  host's jobs.
  """
  @spec schedule_cancellation(map()) :: :ok
  def schedule_cancellation(poll) do
    insert_job(
      %{
        "action" => "send_poll_cancelled",
        "poll_id" => poll.id,
        "user_id" => poll.user_id,
        "title" => poll.title,
        "recipients" => Enum.map(poll.participants, &cancellation_recipient/1)
      },
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

  defp cancellation_recipient(participant) do
    %{
      "id" => participant.id,
      "name" => participant.name,
      "email" => participant.email,
      "locale" => participant.locale,
      "voted_at" => participant.voted_at && DateTime.to_iso8601(participant.voted_at)
    }
  end

  defp maybe_schedule_reminder(poll, %{value: value, unit: unit}) do
    lead_seconds = Reminders.reminder_interval_seconds(value, unit)
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

  # Best-effort: a poll without its reminder or nudge still works, so a
  # failure is logged by `Helpers.insert/2` and not returned. A caller that
  # schedules inside its own transaction still loses that transaction to a
  # failed insert, since Postgres aborts it, and so rolls back as a whole.
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
