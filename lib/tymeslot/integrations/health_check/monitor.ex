defmodule Tymeslot.Integrations.HealthCheck.Monitor do
  @moduledoc """
  Domain: Health State Tracking & Status Intelligence

  Tracks integration health over time and determines status transitions.
  Provides intelligence about when integrations move between healthy,
  degraded, and unhealthy states.
  """

  alias Tymeslot.DatabaseQueries.{CalendarIntegrationQueries, VideoIntegrationQueries}

  @failure_threshold 3
  @recovery_threshold 2
  @check_interval :timer.minutes(30)

  @type health_status :: :healthy | :degraded | :unhealthy
  @type integration_type :: :calendar | :video
  @type health_state :: %{
          failures: non_neg_integer(),
          successes: non_neg_integer(),
          last_check: DateTime.t() | nil,
          status: health_status(),
          backoff_ms: pos_integer(),
          last_error_class: :transient | :hard | nil
        }

  @type transition ::
          {:initial_failure | :became_unhealthy | :became_healthy | :became_degraded | :no_change,
           health_status(), health_status()}

  @doc """
  Creates an initial health state for a new integration.
  """
  @spec initial_state() :: health_state()
  def initial_state do
    %{
      failures: 0,
      successes: 0,
      last_check: nil,
      status: :healthy,
      backoff_ms: @check_interval,
      last_error_class: nil
    }
  end

  @doc """
  Gets the health state for a specific integration from the state map.
  """
  @spec get_state(map(), integration_type(), integer()) :: health_state()
  def get_state(state, type, integration_id) do
    health_map_key = if type == :calendar, do: :calendar_health, else: :video_health
    current_health_map = Map.get(state, health_map_key)
    Map.get(current_health_map, integration_id, initial_state())
  end

  @doc """
  Updates the health state in the GenServer state map.
  """
  @spec put_state(map(), integration_type(), integer(), health_state()) :: map()
  def put_state(state, type, integration_id, health_state) do
    health_map_key = if type == :calendar, do: :calendar_health, else: :video_health
    current_health_map = Map.get(state, health_map_key)
    new_health_map = Map.put(current_health_map, integration_id, health_state)

    if type == :calendar do
      %{state | calendar_health: new_health_map}
    else
      %{state | video_health: new_health_map}
    end
  end

  @doc """
  Updates health state based on check result and error analysis.
  Returns the new health state.
  """
  @spec update_health(health_state(), {:ok, any()} | {:error, any(), :transient | :hard}) ::
          health_state()
  def update_health(health_state, {:ok, _check_result}) do
    %{
      failures: 0,
      successes: health_state.successes + 1,
      last_check: DateTime.utc_now(),
      status: determine_status(0, health_state.successes + 1),
      backoff_ms: @check_interval,
      last_error_class: nil
    }
  end

  def update_health(health_state, {:error, _error_reason, :transient}) do
    %{
      failures: health_state.failures,
      successes: health_state.successes,
      last_check: DateTime.utc_now(),
      status: health_state.status,
      backoff_ms: health_state.backoff_ms,
      last_error_class: :transient
    }
  end

  def update_health(health_state, {:error, _error_reason, :hard}) do
    failures = health_state.failures + 1

    %{
      failures: failures,
      successes: 0,
      last_check: DateTime.utc_now(),
      status: determine_status(failures, 0),
      backoff_ms: @check_interval,
      last_error_class: :hard
    }
  end

  @doc """
  Determines the health status based on failure and success counts.
  """
  @spec determine_status(non_neg_integer(), non_neg_integer()) :: health_status()
  def determine_status(failures, _successes) when failures >= @failure_threshold, do: :unhealthy
  def determine_status(failures, _successes) when failures > 0, do: :degraded
  def determine_status(_failures, successes) when successes >= @recovery_threshold, do: :healthy
  def determine_status(_failures, _successes), do: :degraded

  @doc """
  Detects transitions between health states.
  Returns a tuple describing the transition type and old/new status.
  """
  @spec detect_transition(health_state(), health_state()) :: transition()
  def detect_transition(old_state, new_state) do
    case {old_state.last_check, old_state.status, new_state.status} do
      # Initial check that fails
      {nil, _old_status, :unhealthy} ->
        {:initial_failure, nil, :unhealthy}

      # Initial check that's healthy or degraded (no action needed)
      {nil, _old_status, status} when status != :unhealthy ->
        {:no_change, nil, status}

      # Transition to unhealthy
      {_last_check, old, :unhealthy} when old != :unhealthy ->
        {:became_unhealthy, old, :unhealthy}

      # Recovery to healthy
      {_last_check, :unhealthy, :healthy} ->
        {:became_healthy, :unhealthy, :healthy}

      # Degradation from healthy
      {_last_check, :healthy, :degraded} ->
        {:became_degraded, :healthy, :degraded}

      # No significant transition
      _other ->
        {:no_change, old_state.status, new_state.status}
    end
  end

  @doc """
  Builds a health report for all integrations belonging to a user.
  """
  @spec build_user_report(integer(), map()) :: map()
  def build_user_report(user_id, state) do
    calendar_integrations = CalendarIntegrationQueries.list_all_for_user(user_id)
    video_integrations = VideoIntegrationQueries.list_all_for_user(user_id)

    calendar_health =
      Enum.map(calendar_integrations, fn integration ->
        health = Map.get(state.calendar_health, integration.id, initial_state())

        %{
          id: integration.id,
          provider: integration.provider,
          is_active: integration.is_active,
          health: health
        }
      end)

    video_health =
      Enum.map(video_integrations, fn integration ->
        health = Map.get(state.video_health, integration.id, initial_state())

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

  defp count_by_status(integration_lists, status) do
    integration_lists
    |> List.flatten()
    |> Enum.count(fn integration ->
      integration.health.status == status
    end)
  end
end
