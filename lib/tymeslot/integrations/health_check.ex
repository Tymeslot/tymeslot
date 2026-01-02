defmodule Tymeslot.Integrations.HealthCheck do
  @moduledoc """
  Health check system for monitoring integration status and automatically
  handling failures.

  This module provides:
  - Periodic health checks for all active integrations
  - Automatic deactivation of failing integrations
  - User notifications for integration issues
  - Health status tracking and reporting
  """

  use GenServer
  require Logger

  alias Tymeslot.DatabaseQueries.{CalendarIntegrationQueries, VideoIntegrationQueries}
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter

  @check_interval :timer.minutes(5)
  @failure_threshold 3
  @recovery_threshold 2

  # Type definitions
  @type health_status :: :healthy | :degraded | :unhealthy
  @type integration_type :: :calendar | :video
  @type health_state :: %{
          failures: non_neg_integer(),
          successes: non_neg_integer(),
          last_check: DateTime.t() | nil,
          status: health_status()
        }

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            calendar_health: %{integer() => Tymeslot.Integrations.HealthCheck.health_state()},
            video_health: %{integer() => Tymeslot.Integrations.HealthCheck.health_state()},
            check_timer: reference() | nil
          }
    defstruct calendar_health: %{}, video_health: %{}, check_timer: nil
  end

  # Client API

  @doc """
  Starts the health check process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers a health check for all integrations.
  """
  @spec check_all_integrations() :: :ok
  def check_all_integrations do
    GenServer.cast(__MODULE__, :check_all)
  end

  @doc """
  Gets the current health status for a specific integration.
  """
  @spec get_health_status(integration_type(), integer()) :: health_state() | nil
  def get_health_status(type, integration_id) do
    GenServer.call(__MODULE__, {:get_health_status, type, integration_id})
  end

  @doc """
  Gets health report for all integrations of a user.
  """
  @spec get_user_health_report(integer()) :: map()
  def get_user_health_report(user_id) do
    GenServer.call(__MODULE__, {:get_user_health_report, user_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :check_interval, @check_interval)

    # Schedule first check after a short delay
    Process.send_after(self(), :scheduled_check, 1000)

    state = %State{
      calendar_health: %{},
      video_health: %{},
      check_timer: schedule_next_check(interval)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast(:check_all, state) do
    Logger.info("Manual health check triggered for all integrations")
    new_state = perform_all_health_checks(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get_health_status, :calendar, id}, _from, state) do
    status = Map.get(state.calendar_health, id)
    {:reply, status, state}
  end

  def handle_call({:get_health_status, :video, id}, _from, state) do
    status = Map.get(state.video_health, id)
    {:reply, status, state}
  end

  def handle_call({:get_user_health_report, user_id}, _from, state) do
    report = build_user_health_report(user_id, state)
    {:reply, report, state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    Logger.debug("Running scheduled health check for all integrations")

    new_state = perform_all_health_checks(state)

    # Schedule next check
    timer = schedule_next_check(@check_interval)

    {:noreply, %{new_state | check_timer: timer}}
  end

  # Private Functions

  @spec perform_all_health_checks(State.t()) :: State.t()
  defp perform_all_health_checks(state) do
    state
    |> check_calendar_integrations()
    |> check_video_integrations()
  end

  @spec check_calendar_integrations(State.t()) :: State.t()
  defp check_calendar_integrations(state) do
    integrations = CalendarIntegrationQueries.list_all_active()

    new_health_states =
      Enum.reduce(integrations, state.calendar_health, fn integration, health_acc ->
        health_state = Map.get(health_acc, integration.id, initial_health_state())
        new_health_state = check_integration_health(:calendar, integration, health_state)

        Map.put(health_acc, integration.id, new_health_state)
      end)

    %{state | calendar_health: new_health_states}
  end

  @spec check_video_integrations(State.t()) :: State.t()
  defp check_video_integrations(state) do
    integrations = VideoIntegrationQueries.list_all_active()

    new_health_states =
      Enum.reduce(integrations, state.video_health, fn integration, health_acc ->
        health_state = Map.get(health_acc, integration.id, initial_health_state())
        new_health_state = check_integration_health(:video, integration, health_state)

        Map.put(health_acc, integration.id, new_health_state)
      end)

    %{state | video_health: new_health_states}
  end

  @spec check_integration_health(integration_type(), map(), health_state()) :: health_state()
  defp check_integration_health(type, integration, health_state) do
    start_time = System.monotonic_time(:millisecond)

    result = do_check_integration_health(type, integration)

    duration = System.monotonic_time(:millisecond) - start_time

    # Record telemetry
    :telemetry.execute(
      [:tymeslot, :integration, :health_check],
      %{duration: duration},
      %{
        type: type,
        provider: integration.provider,
        integration_id: integration.id,
        user_id: integration.user_id,
        success: match?({:ok, _}, result)
      }
    )

    # Update health state
    new_health_state = update_health_state(health_state, result)

    # Handle state transitions
    handle_health_transition(type, integration, health_state, new_health_state)

    new_health_state
  end

  defp do_check_integration_health(:calendar, integration) do
    Calendar.test_connection(integration)
  rescue
    _e in [UndefinedFunctionError] -> {:error, :module_unavailable}
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp do_check_integration_health(:video, integration) do
    provider_atom = safe_to_existing_atom(integration.provider)
    decrypted = VideoIntegrationSchema.decrypt_credentials(integration)
    config = video_provider_config(provider_atom, integration, decrypted)

    case provider_atom do
      nil ->
        {:error, :unsupported_provider}

      _ ->
        do_test_connection(provider_atom, config)
    end
  end

  defp do_test_connection(provider_atom, config) do
    ProviderAdapter.test_connection(provider_atom, config)
  rescue
    _e in [UndefinedFunctionError] -> {:error, :module_unavailable}
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp safe_to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_existing_atom(_), do: nil

  defp video_provider_config(:mirotalk, integration, decrypted),
    do: %{api_key: decrypted.api_key, base_url: integration.base_url}

  defp video_provider_config(:google_meet, integration, decrypted),
    do: %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token,
      token_expires_at: integration.token_expires_at,
      oauth_scope: integration.oauth_scope,
      integration_id: integration.id,
      user_id: integration.user_id
    }

  defp video_provider_config(:teams, integration, decrypted),
    do: %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token,
      token_expires_at: integration.token_expires_at,
      integration_id: integration.id,
      user_id: integration.user_id
    }

  defp video_provider_config(_other, _integration, _decrypted), do: %{}

  @spec update_health_state(health_state(), {:ok, any()} | {:error, any()}) :: health_state()
  defp update_health_state(health_state, {:ok, _}) do
    %{
      failures: 0,
      successes: health_state.successes + 1,
      last_check: DateTime.utc_now(),
      status: determine_status(0, health_state.successes + 1)
    }
  end

  defp update_health_state(health_state, {:error, reason}) do
    failures = health_state.failures + 1

    Logger.warning("Integration health check failed",
      reason: reason,
      failures: failures,
      threshold: @failure_threshold
    )

    %{
      failures: failures,
      successes: 0,
      last_check: DateTime.utc_now(),
      status: determine_status(failures, 0)
    }
  end

  @spec determine_status(non_neg_integer(), non_neg_integer()) :: health_status()
  defp determine_status(failures, _) when failures >= @failure_threshold, do: :unhealthy
  defp determine_status(failures, _) when failures > 0, do: :degraded
  defp determine_status(_, successes) when successes >= @recovery_threshold, do: :healthy
  defp determine_status(_, _), do: :degraded

  @spec handle_health_transition(integration_type(), map(), health_state(), health_state()) :: :ok
  defp handle_health_transition(type, integration, old_state, new_state) do
    case {old_state.last_check, old_state.status, new_state.status} do
      # Skip logging for initial checks that aren't failures
      {nil, _, status} when status != :unhealthy ->
        :ok

      # Log and deactivate for initial failures
      {nil, _, :unhealthy} ->
        handle_initial_failure(type, integration)

      # Handle status transitions
      {_, old_status, new_status} ->
        handle_status_transition(type, integration, old_status, new_status, new_state)
    end
  end

  @spec handle_initial_failure(integration_type(), map()) :: :ok
  defp handle_initial_failure(type, integration) do
    Logger.error("Integration health check failed on first attempt",
      type: type,
      integration_id: integration.id,
      provider: integration.provider,
      user_id: integration.user_id
    )

    deactivate_integration(type, integration)
  end

  @spec handle_status_transition(
          integration_type(),
          map(),
          health_status(),
          health_status(),
          health_state()
        ) :: :ok
  defp handle_status_transition(type, integration, old_status, new_status, new_state) do
    case {old_status, new_status} do
      # Transition to unhealthy - deactivate and notify
      {old, :unhealthy} when old != :unhealthy ->
        handle_unhealthy_transition(type, integration)

      # Transition to healthy - notify recovery
      {:unhealthy, :healthy} ->
        handle_recovery_transition(type, integration)

      # Transition to degraded - log warning
      {:healthy, :degraded} ->
        handle_degraded_transition(type, integration, new_state)

      _ ->
        :ok
    end
  end

  @spec handle_unhealthy_transition(integration_type(), map()) :: :ok
  defp handle_unhealthy_transition(type, integration) do
    Logger.error("Integration health critical - deactivating",
      type: type,
      integration_id: integration.id,
      provider: integration.provider,
      user_id: integration.user_id
    )

    deactivate_integration(type, integration)
  end

  @spec handle_recovery_transition(integration_type(), map()) :: :ok
  defp handle_recovery_transition(type, integration) do
    Logger.info("Integration health recovered",
      type: type,
      integration_id: integration.id,
      provider: integration.provider,
      user_id: integration.user_id
    )

    :ok
  end

  @spec handle_degraded_transition(integration_type(), map(), health_state()) :: :ok
  defp handle_degraded_transition(type, integration, new_state) do
    Logger.warning("Integration health degraded",
      type: type,
      integration_id: integration.id,
      provider: integration.provider,
      user_id: integration.user_id,
      failures: new_state.failures
    )

    :ok
  end

  @spec deactivate_integration(integration_type(), map()) :: :ok
  defp deactivate_integration(:calendar, integration) do
    case CalendarIntegrationQueries.update(integration, %{is_active: false}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to deactivate calendar integration",
          integration_id: integration.id,
          reason: reason
        )
    end
  end

  defp deactivate_integration(:video, integration) do
    case VideoIntegrationQueries.update(integration, %{is_active: false}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to deactivate video integration",
          integration_id: integration.id,
          reason: reason
        )
    end
  end

  @spec build_user_health_report(integer(), State.t()) :: map()
  defp build_user_health_report(user_id, state) do
    calendar_integrations = CalendarIntegrationQueries.list_all_for_user(user_id)
    video_integrations = VideoIntegrationQueries.list_all_for_user(user_id)

    calendar_health =
      Enum.map(calendar_integrations, fn integration ->
        health = Map.get(state.calendar_health, integration.id, initial_health_state())

        %{
          id: integration.id,
          provider: integration.provider,
          is_active: integration.is_active,
          health: health
        }
      end)

    video_health =
      Enum.map(video_integrations, fn integration ->
        health = Map.get(state.video_health, integration.id, initial_health_state())

        %{
          id: integration.id,
          provider: integration.provider,
          is_active: integration.is_active,
          health: health
        }
      end)

    %{
      calendar_integrations: calendar_health,
      video_integrations: video_health,
      summary: %{
        healthy_count: count_by_status([calendar_health, video_health], :healthy),
        degraded_count: count_by_status([calendar_health, video_health], :degraded),
        unhealthy_count: count_by_status([calendar_health, video_health], :unhealthy)
      }
    }
  end

  @spec count_by_status(list(list(map())), health_status()) :: non_neg_integer()
  defp count_by_status(integration_lists, status) do
    integration_lists
    |> List.flatten()
    |> Enum.count(fn integration ->
      integration.health.status == status
    end)
  end

  @spec initial_health_state() :: health_state()
  defp initial_health_state do
    %{
      failures: 0,
      successes: 0,
      last_check: nil,
      status: :healthy
    }
  end

  @spec schedule_next_check(pos_integer()) :: reference()
  defp schedule_next_check(interval) do
    Process.send_after(self(), :scheduled_check, interval)
  end
end
