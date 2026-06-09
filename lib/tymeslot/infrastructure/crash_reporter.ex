defmodule Tymeslot.Infrastructure.CrashReporter do
  @moduledoc """
  Global `:logger` handler that turns unhandled process crashes into admin alerts.

  Installed once at startup (`attach/0`). Every abnormal process exit in the BEAM —
  a raised exception in a Phoenix request, a dying LiveView process, a terminating
  GenServer, a throwing supervised Task — is logged by OTP at `:error` with a
  `crash_reason` metadata field. This handler matches those events, classifies the
  crash, and forwards it to `Tymeslot.Infrastructure.AdminAlerts.report/2`.

  It deliberately does **not**:

    * capture plain `Logger.error/warning` messages — only events carrying
      `crash_reason`; alerting on every error log would be noise;
    * capture Oban job failures — those are owned by
      `Tymeslot.Infrastructure.ObanFailureAlerter` via Oban telemetry.

  ## Why a `:logger` handler

  It is the single seam every BEAM crash flows through, so one `attach/0` covers
  web, workers, GenServers and tasks without wiring `AdminAlerts` into individual
  functions — mirroring how `FileSink` and `MetadataRedactor` install
  `:logger` handlers/filters.

  ## Safety

    * The handler callback does no DB work — it filters and offloads the report to
      `Tymeslot.TaskSupervisor`, so a slow or failing alert path can never block or
      kill the logging pipeline.
    * The offloaded work is wrapped so a failure inside the alert path cannot
      produce a new crash event that re-enters this handler (loop prevention).
    * Normal exits and client-error (4xx) exceptions are filtered out; a global
      rate limit caps alert volume during a crash storm.
  """

  @normal_exits [:normal, :shutdown]

  @doc """
  Returns true if a crash of this kind/reason should raise an admin alert.

  Orderly exits (`:normal`, `:shutdown`, `{:shutdown, _}`) and client-error (4xx)
  exceptions are not reportable. Public for testing.
  """
  @spec reportable?(atom(), term()) :: boolean()
  def reportable?(:exit, reason) when reason in @normal_exits, do: false
  def reportable?(:exit, {:shutdown, _reason}), do: false

  def reportable?(_kind, reason) when is_exception(reason) do
    reason.__struct__ not in ignored_exceptions()
  end

  def reportable?(_kind, _reason), do: true

  defp ignored_exceptions do
    Application.get_env(:tymeslot, :crash_reporter_ignored_exceptions, [])
  end
end
