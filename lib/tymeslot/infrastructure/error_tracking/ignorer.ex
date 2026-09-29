defmodule Tymeslot.Infrastructure.ErrorTracking.Ignorer do
  @moduledoc """
  Keeps client errors out of ErrorTracker: 4xx exceptions raised while
  serving a request or a LiveView, by the rule in
  `Tymeslot.Infrastructure.ErrorTracking.ClientError` (the same exception
  raised in a job or any other process is tracked), and events no
  `handle_event/3` clause matches, by the rule in
  `Tymeslot.Infrastructure.ErrorTracking.UnmatchedEvent`. Last, it drops the
  occurrences of one error beyond the per-minute cap of
  `Tymeslot.Infrastructure.ErrorTracking.Throttle`; asked last, so ignored
  noise never uses up an error's allowance.

  ErrorTracker calls this without a rescue, from telemetry handlers that
  telemetry detaches on the first raise, so a bug here must never escape: it
  would switch error tracking off until the next restart. Any failure is
  logged and the error is tracked.
  """

  @behaviour ErrorTracker.Ignorer

  alias Tymeslot.Infrastructure.ErrorTracking.ClientError
  alias Tymeslot.Infrastructure.ErrorTracking.Throttle
  alias Tymeslot.Infrastructure.ErrorTracking.UnmatchedEvent
  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @impl ErrorTracker.Ignorer
  def ignore?(error, context) do
    ClientError.client_error_kind?(error.kind, context) or
      UnmatchedEvent.error?(error.kind, error.reason) or
      not Throttle.allow?(error.fingerprint)
  rescue
    exception ->
      Logger.warning("ErrorTracker ignorer failed; tracking the error",
        exception: LogFormat.reason(exception.__struct__)
      )

      false
  end
end
