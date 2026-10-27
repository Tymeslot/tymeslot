defmodule Tymeslot.Notifications.DispatchInTransactionError do
  @moduledoc """
  Raised by `Tymeslot.Notifications.Events.dispatch_deferred/1` when it is
  called inside a database transaction. The integration fan-out is
  best-effort, and a database error in one of its dispatchers would leave the
  surrounding transaction unable to commit, so it runs only once the caller's
  transaction has committed. A caller that opens one has to take the pending
  fan-out back and dispatch it after its own commit.

  Its own exception, rather than an `ArgumentError`, so that a blanket
  best-effort rescue around a dispatch can let it through.
  """

  defexception message:
                 "integration fan-out dispatched inside a transaction: return the " <>
                   "pending fan-out to the caller that opened it and dispatch after its commit"
end
