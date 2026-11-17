defmodule Tymeslot.Notifications.Events.Guard do
  @moduledoc """
  The containment every notification event in `Tymeslot.Notifications.Events`
  and `Tymeslot.Notifications.Events.Seats` shares: an email step that
  raises is reported and returned as an error, only a storage failure is
  worth a retry, and the seat reads around an integration dispatch are as
  best-effort as the dispatch itself.
  """

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat

  # The email step is the only one of these dispatches that renders templates
  # in-process, so a payload the templates don't fit raises instead of
  # returning `{:error, _}`. Everything sequenced after it — reminder jobs,
  # webhooks, Telegram, Slack — is best-effort by design, and an escaping
  # exception used to skip all of them while the meeting change itself stood
  # (issue #76: a reschedule that never dispatched `meeting.rescheduled`).
  # Contain it here so one failed channel cannot silence the others; the caller
  # still learns the emails failed through the error tuple it already handles.
  @doc """
  Runs `fun`, the email step of an event, turning an exception it raises
  into `{:error, {:notifications_failed, exception}}`, reported.
  """
  @spec send_notifications(atom(), term(), (-> term())) :: term()
  def send_notifications(event, meeting, fun) do
    fun.()
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{
        event: event,
        meeting_id: Map.get(meeting, :id)
      })

      {:error, {:notifications_failed, exception}}
  end

  # An announcement's caller rolls the booking back on an error, for a retry.
  # Only a failing queue or database can be helped by one: a fault composing
  # the emails (a bug, an odd legacy row) fails the same way every time, and
  # rolling back would refuse the booking for good, or answer a paid
  # checkout's webhook with a 503 for days. Such a fault is reported where it
  # was rescued (`send_notifications/3`) and the booking goes ahead without
  # its emails, as one that cannot be emailed does (`{:ok, :not_sendable}`).
  @doc """
  The result of `send_notifications/3` as the caller should act on it: a
  storage failure stays an error, for a retry; any other failure becomes
  `{:ok, :not_sendable}`, reported.
  """
  @spec retryable_only(term(), atom(), term()) :: term()
  def retryable_only({:error, {:notifications_failed, exception}} = error, event, meeting) do
    if storage_failure?(exception) do
      error
    else
      Logger.error("Announcing without emails: composing them failed",
        event: event,
        meeting_id: Map.get(meeting, :id),
        error: LogFormat.reason(exception)
      )

      {:ok, :not_sendable}
    end
  end

  def retryable_only(result, _event, _meeting), do: result

  # The database refused or dropped the write; in a transaction, Postgres has
  # also aborted it, so nothing could commit anyway.
  defp storage_failure?(%struct{})
       when struct in [
              DBConnection.ConnectionError,
              DBConnection.OwnershipError,
              Postgrex.Error,
              Ecto.ConstraintError,
              Ecto.StaleEntryError
            ],
       do: true

  defp storage_failure?(_exception), do: false

  # Building a seat's view reads the database (its live seats, the seat
  # count), which the per-channel guard below does not cover. It is as
  # best-effort as the channels themselves, so it gets a guard of its own.
  @doc """
  Runs `fun`, which reads a group meeting's seats around an integration
  dispatch, reporting rather than raising what it raises.
  """
  @spec seat_guard(atom() | String.t(), term(), (-> term())) :: term()
  def seat_guard(event, meeting, fun) do
    fun.()
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{
        channel: :seats,
        event: event,
        meeting_id: Map.get(meeting, :id)
      })

      {:error, {:dispatch_failed, exception}}
  end
end
