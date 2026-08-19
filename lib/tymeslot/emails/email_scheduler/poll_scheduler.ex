defmodule Tymeslot.Emails.EmailScheduler.PollScheduler do
  @moduledoc """
  Schedules poll deadline reminders and host nudges via Oban.

  Two jobs bracket a poll with a deadline: a reminder to unvoted participants 24
  hours before it closes, and a nudge to the host once it has passed. A separate
  immediate nudge fires the moment every participant has voted. Cancelling or
  confirming a poll deletes any of these that are still pending.
  """

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Jobs
  alias Tymeslot.Workers.EmailWorker

  require Logger

  # 10 years in seconds — dedupe across arbitrarily long lead times.
  @unique_period 315_360_000
  # Reminders go out 24 hours before the deadline.
  @reminder_lead_seconds 86_400

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
          error: Helpers.format_insert_error(reason)
        )

        :ok
    end
  end

  defp unique_opts(keys) do
    [period: @unique_period, fields: [:args, :queue], keys: keys]
  end
end
