defmodule Tymeslot.Emails.EmailScheduler.SessionScheduler do
  @moduledoc """
  Schedules the organiser's participant list for a planned session
  (`Tymeslot.Meetings.PlannedSessions`) for the moment its registration
  closes. Sent by
  `Tymeslot.Workers.EmailWorkerHandlers.PlannedSessionEmails`, which
  re-checks the session when it runs, so cancelling a session needs no job
  deleted here.

  There is one pending list per session. Scheduling it again, when the
  session or its registration close has moved, moves the pending job to the
  new time; once a list has gone out, a registration that reopens and
  closes again sends a new one.
  """

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Workers.EmailWorker

  require Logger

  @action "send_registration_closed"
  # 10 years in seconds — one pending list per session, however far ahead it is planned.
  @unique_period 315_360_000

  @doc "The worker action this module schedules."
  @spec action() :: String.t()
  def action, do: @action

  @doc """
  Schedules the participant list for `session` at its registration close,
  or moves the pending one there. A scheduling failure is logged and not
  raised: the session stands either way.
  """
  @spec schedule_registration_closed(map()) :: :ok
  def schedule_registration_closed(session) do
    args = %{"action" => @action, "meeting_id" => session.id}

    job =
      EmailWorker.new(args,
        queue: :emails,
        priority: 2,
        scheduled_at: PlannedSessions.registration_closes_at(session),
        unique: [
          period: @unique_period,
          fields: [:args, :queue],
          keys: [:action, :meeting_id],
          states: :incomplete
        ],
        replace: [scheduled: [:scheduled_at], available: [:scheduled_at]]
      )

    case Oban.insert(job) do
      {:ok, _job} ->
        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule participant list email",
          meeting_id: session.id,
          error: Helpers.format_insert_error(reason)
        )

        :ok
    end
  end
end
