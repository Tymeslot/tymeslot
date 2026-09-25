defmodule Tymeslot.Infrastructure.ErrorTracking.Ignorer do
  @moduledoc """
  Keeps client errors out of ErrorTracker: 4xx exceptions raised while
  serving a request or a LiveView, by the rule in
  `Tymeslot.Infrastructure.ErrorTracking.ClientError`. The same exception
  raised in a job or any other process is tracked.

  ErrorTracker calls this without a rescue, from telemetry handlers that
  telemetry detaches on the first raise, so a bug here must never escape: it
  would switch error tracking off until the next restart. Any failure is
  logged and the error is tracked.
  """

  @behaviour ErrorTracker.Ignorer

  alias Tymeslot.Infrastructure.ErrorTracking.ClientError

  require Logger

  @impl ErrorTracker.Ignorer
  def ignore?(error, context) do
    ClientError.client_error_kind?(error.kind, context)
  rescue
    exception ->
      Logger.warning("ErrorTracker ignorer failed; tracking the error",
        exception: inspect(exception.__struct__)
      )

      false
  end
end
