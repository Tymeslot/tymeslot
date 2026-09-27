defmodule Tymeslot.Infrastructure.ErrorTracking.SafeIntegrations do
  @moduledoc """
  Re-attaches ErrorTracker's Phoenix, LiveView and Oban integrations behind a
  handler that cannot raise.

  ErrorTracker attaches its integrations as telemetry handlers when its
  application starts. Their `:exception` handlers call `ErrorTracker.report/3`,
  which writes to the database without rescuing, and telemetry detaches a
  handler that raises, together with every event attached under the same
  handler id. One `DBConnection.ConnectionError` while the pool is exhausted
  would therefore stop every exception from being recorded, and the `:start`
  handlers that set the request, LiveView and job context with it, until the
  next restart.

  `install/0` detaches the library's handlers and attaches one per
  integration that calls the library's own `handle_event/4` inside
  `try`/`rescue`/`catch`. A failure is logged, naming only the integration and
  the failure's module or kind, and dropped. It is never reported to
  ErrorTracker, which is what just failed.

  The handler ids and events below are copied from
  `ErrorTracker.Integrations.Oban` and `ErrorTracker.Integrations.Phoenix`.
  The test suite attaches the library's own handlers and compares, so an
  upgrade that renames either fails there instead of leaving the unguarded
  handlers attached.
  """

  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @integrations [
    {ErrorTracker.Integrations.Oban, [[:oban, :job, :start], [:oban, :job, :exception]]},
    {ErrorTracker.Integrations.Phoenix,
     [
       [:phoenix, :router_dispatch, :start],
       [:phoenix, :router_dispatch, :exception],
       [:phoenix, :live_view, :mount, :start],
       [:phoenix, :live_view, :mount, :exception],
       [:phoenix, :live_view, :handle_params, :start],
       [:phoenix, :live_view, :handle_params, :exception],
       [:phoenix, :live_view, :handle_event, :exception],
       [:phoenix, :live_view, :render, :exception],
       [:phoenix, :live_component, :update, :exception],
       [:phoenix, :live_component, :handle_event, :exception]
     ]}
  ]

  @doc "The integrations replaced, each with the events its handler listens to."
  @spec integrations() :: [{module(), [[atom()]]}]
  def integrations, do: @integrations

  @doc """
  Replaces ErrorTracker's integration handlers with guarded ones. Idempotent,
  so safe to call on application restart inside the same BEAM.
  """
  @spec install() :: :ok
  def install, do: Enum.each(@integrations, &install_integration/1)

  defp install_integration({integration, events}) do
    handler_id = {__MODULE__, integration}
    guarded = :telemetry.detach(handler_id)
    library = :telemetry.detach(integration)

    if guarded != :ok and library != :ok do
      Logger.warning("ErrorTracker integration handler not found; attaching a guarded one",
        integration: LogFormat.reason(integration)
      )
    end

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, integration)
  end

  @doc false
  @spec handle_event([atom()], map(), map(), module()) :: :ok
  def handle_event(event, measurements, metadata, integration) do
    _result = integration.handle_event(event, measurements, metadata, :no_config)
    :ok
  rescue
    exception -> log_failure(integration, exception.__struct__)
  catch
    kind, _reason -> log_failure(integration, kind)
  end

  # A plain log line with no crash_reason, so `CrashReporter` does not take
  # it for a crash and try to record it in the database that just failed.
  defp log_failure(integration, error) do
    Logger.error("ErrorTracker failed to record an exception",
      integration: LogFormat.reason(integration),
      error: LogFormat.reason(error)
    )

    :ok
  end
end
