defmodule Tymeslot.Meetings.CommittedStep do
  @moduledoc """
  Runs a best-effort step after an approval-gate transition has committed,
  shared by `Tymeslot.Meetings.Approval` and `Tymeslot.Meetings.ApprovalRelease`.
  """

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Notifications.DispatchInTransactionError

  @doc """
  Runs `fun` for a meeting whose row is already committed (confirmed by
  `Approval`, released by `ApprovalRelease`) and cannot be undone by a caller
  retrying.

  A crash in one step must not stop the next, nor turn a real approval or
  release into an `{:error, ...}` the caller has to explain: the transition
  already succeeded, and each step is independently retried or logged by its
  own module on an ordinary `{:error, _}`. This only guards against the
  unexpected raise; `{:error, _}` returns are each module's own job to log.
  A fan-out dispatched inside a transaction is not one: it is a caller wired
  up wrong, and is let through to fail loudly.
  """
  @spec run(Meeting.t(), String.t(), (-> term())) :: term()
  def run(meeting, step, fun) do
    fun.()
  rescue
    exception in DispatchInTransactionError ->
      reraise exception, __STACKTRACE__

    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{step: step, meeting_id: meeting.id})
  end
end
