defmodule Tymeslot.Infrastructure.ErrorTracking.Ignorer do
  @moduledoc """
  Keeps client-error (4xx) exceptions out of ErrorTracker, by the rule in
  `Tymeslot.Infrastructure.ErrorTracking.ClientError`.

  ErrorTracker calls this without a rescue, from telemetry handlers that
  telemetry detaches on the first raise, so a bug here must never escape: it
  would switch error tracking off until the next restart. Any failure is
  logged and the error is tracked.
  """

  @behaviour ErrorTracker.Ignorer

  alias Tymeslot.Infrastructure.ErrorTracking.ClientError

  require Logger

  @impl ErrorTracker.Ignorer
  def ignore?(error, _context) do
    ClientError.client_error_kind?(error.kind)
  rescue
    exception ->
      Logger.warning("ErrorTracker ignorer failed; tracking the error",
        exception: inspect(exception.__struct__)
      )

      false
  end
end
