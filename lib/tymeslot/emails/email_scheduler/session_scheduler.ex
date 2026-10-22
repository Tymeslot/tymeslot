defmodule Tymeslot.Emails.EmailScheduler.SessionScheduler do
  @moduledoc """
  Schedules the organiser's participant list for a planned session
  (`Tymeslot.Meetings.PlannedSessions`) for the moment its registration
  closes. Sent by
  `Tymeslot.Notifications.Email.PlannedSessionEmails`, which
  re-checks the session when it runs, so cancelling a session needs no job
  deleted here.

  There is one pending list per session. Scheduling it again, when the
  session or its registration close has moved, moves the pending job to the
  new time; once a list has gone out, a registration that reopens and
  closes again sends a new one.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Workers.EmailWorker

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
        # A retryable list has a backoff time in `scheduled_at`; a moved
        # close replaces it too, so the list goes at the new close rather
        # than waiting out the backoff. The job keeps its id, so its
        # `DeliveryClaims` still stop a retry re-sending a copy that went.
        replace: [
          scheduled: [:scheduled_at],
          available: [:scheduled_at],
          retryable: [:scheduled_at]
        ]
      )

    _result = Helpers.insert(job, meeting_id: session.id)
    :ok
  end

  @doc """
  Follows a change to `previous`'s time or registration close, now `current`.

  Only a registration that is, or was until this change, still open has a
  list to move or owe: one that had already closed, and closes again at a
  time already past, has sent its list, and scheduling it again would send
  the same list once more.
  """
  @spec reschedule_registration_closed(map(), map(), DateTime.t()) :: :ok
  def reschedule_registration_closed(previous, current, now \\ Clock.utc_now()) do
    if open_at?(previous, now) or open_at?(current, now),
      do: schedule_registration_closed(current),
      else: :ok
  end

  defp open_at?(session, now),
    do: DateTime.compare(PlannedSessions.registration_closes_at(session), now) == :gt
end
