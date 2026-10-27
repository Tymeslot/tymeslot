defmodule Tymeslot.Integrations.Calendar.Outlook.SyncCycle do
  @moduledoc """
  One refresh of an Outlook Calendar integration from Microsoft Graph, with
  no knowledge of the job running it.

  With a stored `graph_delta_link`, the cycle follows it
  (`DeltaSync.fetch_and_apply/1`); without one it bootstraps a fresh delta
  baseline (`OutlookCalendarAPI.bootstrap_sync/1`) and opportunistically
  registers a webhook subscription.

  A link old enough to be replaced (`DeltaSync.rebootstrap_due?/2`) is still
  followed first, then replaced by a bootstrap. The bootstrap only upserts
  what it reads, so the removals pending on the old link would otherwise
  never reach the cache; and a bootstrap that keeps failing (a calendar past
  its page cap, say) would otherwise freeze the cache, since every later
  refresh would try the bootstrap again and nothing else. A bootstrap that
  fails after the old link was followed keeps that result: the cache is as
  current as the old link can make it, and the next refresh tries the
  bootstrap again.

  A completed cycle broadcasts `SyncBroadcast.broadcast_sync_complete/2`, so
  the dashboard's progress counter clears.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.DeltaSync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis

  @typedoc """
  Which read failed, and whether the failure is the remote's and passing
  (`:transient`) or not (`:hard`), in `ErrorAnalysis`'s terms.
  """
  @type failure :: {:delta_sync_failed | :bootstrap_failed, ErrorAnalysis.error_class()}

  @doc """
  Refreshes the Outlook integration `integration`.

  Returns `:ok`, `{:error, :unauthorized}` when Microsoft refused the
  credentials, or `{:error, t:failure/0}`.
  """
  @spec run(CalendarIntegrationSchema.t()) :: :ok | {:error, :unauthorized | failure()}
  def run(%CalendarIntegrationSchema{graph_delta_link: nil} = integration),
    do: bootstrap(integration)

  def run(%CalendarIntegrationSchema{} = integration) do
    if DeltaSync.rebootstrap_due?(integration),
      do: delta_then_bootstrap(integration),
      else: delta_refresh(integration)
  end

  # A refused credential is the one bootstrap failure that still decides the
  # outcome after the old link was followed.
  defp delta_then_bootstrap(integration) do
    case DeltaSync.fetch_and_apply(integration) do
      {:error, :unauthorized} ->
        {:error, :unauthorized}

      delta_result ->
        case run_bootstrap(reload(integration)) do
          {:error, :unauthorized, _message} ->
            {:error, :unauthorized}

          failure when delta_result == :ok and failure != :ok ->
            log_bootstrap_failure(integration, failure)
            broadcast_complete(integration)
            :ok

          bootstrap_result ->
            bootstrap_outcome(bootstrap_result, integration)
        end
    end
  end

  # The delta pass may have stored a new link and refreshed the token.
  defp reload(integration) do
    case CalendarIntegrationQueries.get(integration.id) do
      {:ok, reloaded} -> reloaded
      _gone_or_unreadable -> integration
    end
  end

  defp delta_refresh(integration) do
    case DeltaSync.fetch_and_apply(integration) do
      :ok ->
        broadcast_complete(integration)
        :ok

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, class} ->
        # DeltaSync clears the stored link on obsolete-endpoint detection (old
        # `events/delta`) or 410 expiry. Reload to see whether that happened:
        # if so, finish the cycle by bootstrapping rather than relying on a
        # retry to converge on the second pass.
        case CalendarIntegrationQueries.get(integration.id) do
          {:ok, %{graph_delta_link: nil} = reloaded} -> bootstrap(reloaded)
          _other -> {:error, {:delta_sync_failed, class}}
        end
    end
  end

  defp bootstrap(integration),
    do: integration |> run_bootstrap() |> bootstrap_outcome(integration)

  defp run_bootstrap(integration) do
    case Config.outlook_calendar_api_module().bootstrap_sync(integration) do
      {:ok, updated} ->
        # Opportunistic webhook (re-)registration. Non-fatal: a seeded delta
        # link is enough on its own, the next click/sweep can keep things current.
        Config.outlook_calendar_api_module().register_graph_subscription(updated)
        broadcast_complete(updated)
        :ok

      error ->
        error
    end
  end

  defp bootstrap_outcome(:ok, _integration), do: :ok

  defp bootstrap_outcome({:error, :unauthorized, _message}, _integration),
    do: {:error, :unauthorized}

  defp bootstrap_outcome(error, integration) do
    log_bootstrap_failure(integration, error)
    {:error, {:bootstrap_failed, error_class(error)}}
  end

  defp log_bootstrap_failure(integration, error) do
    Logger.warning("Outlook bootstrap failed during refresh",
      calendar_integration_id: integration.id,
      error: LogFormat.reason(error)
    )
  end

  defp error_class({:error, type, _message}) when is_atom(type),
    do: ErrorAnalysis.classify_error(type)

  defp error_class({:error, reason}), do: ErrorAnalysis.classify_error(reason)
  defp error_class(_other), do: :hard

  defp broadcast_complete(integration) do
    SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
  end
end
