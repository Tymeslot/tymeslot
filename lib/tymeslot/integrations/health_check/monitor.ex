defmodule Tymeslot.Integrations.HealthCheck.Monitor do
  @moduledoc """
  Domain: Health State Tracking & Status Intelligence

  Tracks integration health over time and determines status transitions.
  Provides intelligence about when integrations move between healthy,
  degraded, and unhealthy states.

  Health state is persisted to the `integration_health_states` table so
  that tracking survives process restarts.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema

  @failure_threshold 3
  @recovery_threshold 2
  @check_interval :timer.minutes(30)
  @max_backoff_ms :timer.hours(1)
  # On the very first transition into :unhealthy, override the standard 1 h
  # hard backoff with a quick 15-minute re-probe. This catches the common case
  # where the user fixes their integration server-side immediately after the
  # third probe fails — without the override, the badge would persist for up
  # to an hour even though the integration is already working again.
  # Subsequent failed probes while still :unhealthy revert to the 1 h cadence
  # so we don't hammer a genuinely broken server.
  @first_unhealthy_recovery_probe_ms :timer.minutes(15)

  @type health_status :: :healthy | :degraded | :unhealthy
  @type integration_type :: :calendar | :video
  @type health_state :: %{
          user_id: integer() | nil,
          failures: non_neg_integer(),
          consecutive_hard_failures: non_neg_integer(),
          successes: non_neg_integer(),
          last_check_at: DateTime.t() | nil,
          status: health_status(),
          backoff_ms: pos_integer(),
          last_error_class: :transient | :hard | nil,
          became_unhealthy_at: DateTime.t() | nil,
          notification_sent_at: DateTime.t() | nil
        }

  @type transition ::
          {:initial_failure | :became_unhealthy | :became_healthy | :became_degraded | :no_change,
           health_status() | nil, health_status()}

  @doc """
  Creates an initial health state for a new integration.
  """
  @spec initial_state() :: health_state()
  def initial_state do
    %{
      user_id: nil,
      failures: 0,
      consecutive_hard_failures: 0,
      successes: 0,
      last_check_at: nil,
      status: :healthy,
      backoff_ms: @check_interval,
      last_error_class: nil,
      became_unhealthy_at: nil,
      notification_sent_at: nil
    }
  end

  @doc """
  Gets the health state for an integration from the database.
  Creates a default healthy record if none exists.
  """
  @spec get_state(integration_type(), integer(), integer()) :: health_state()
  def get_state(type, integration_id, user_id) do
    case IntegrationHealthStateQueries.get_or_init(type, integration_id, user_id) do
      {:ok, record} -> from_db_record(record)
      {:error, :not_found} -> initial_state()
    end
  end

  @doc """
  Persists the health state for an integration to the database.
  Updates the existing record (created by get_state/get_or_init).
  """
  @spec put_state(integration_type(), integer(), health_state()) :: {non_neg_integer(), nil}
  def put_state(type, integration_id, health_state) do
    attrs = to_db_attrs(health_state)
    IntegrationHealthStateQueries.update_fields(type, integration_id, Map.to_list(attrs))
  end

  @doc """
  Updates health state based on check result and error analysis.
  Returns the new health state.
  """
  @spec update_health(health_state(), {:ok, any()} | {:error, any(), :transient | :hard}) ::
          health_state()
  def update_health(health_state, {:ok, _check_result}) do
    %{
      health_state
      | failures: 0,
        consecutive_hard_failures: 0,
        successes: health_state.successes + 1,
        last_check_at: DateTime.utc_now(),
        status: determine_status(0, health_state.successes + 1),
        backoff_ms: @check_interval,
        last_error_class: nil
    }
  end

  def update_health(health_state, {:error, _error_reason, :transient}) do
    new_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :transient)

    # When backoff has reached max, the same transient error has persisted across
    # multiple checks (e.g. econnrefused for over an hour). Start incrementing
    # the failure counter so the integration eventually reaches :unhealthy and
    # triggers the 48h user notification.
    if health_state.backoff_ms >= @max_backoff_ms do
      failures = health_state.failures + 1
      new_status = determine_status(failures, 0)

      became_unhealthy_at =
        if new_status == :unhealthy and is_nil(health_state.became_unhealthy_at),
          do: DateTime.utc_now(),
          else: health_state.became_unhealthy_at

      %{
        health_state
        | failures: failures,
          consecutive_hard_failures: 0,
          successes: 0,
          last_check_at: DateTime.utc_now(),
          status: new_status,
          backoff_ms: new_backoff,
          last_error_class: :transient,
          became_unhealthy_at: became_unhealthy_at
      }
    else
      %{
        health_state
        | consecutive_hard_failures: 0,
          last_check_at: DateTime.utc_now(),
          backoff_ms: new_backoff,
          last_error_class: :transient
      }
    end
  end

  def update_health(health_state, {:error, _error_reason, :hard}) do
    failures = health_state.failures + 1
    consecutive_hard_failures = health_state.consecutive_hard_failures + 1
    new_status = determine_status(failures, 0)
    just_became_unhealthy? = new_status == :unhealthy and health_state.status != :unhealthy

    new_backoff =
      if just_became_unhealthy? do
        @first_unhealthy_recovery_probe_ms
      else
        ErrorAnalysis.calculate_next_backoff(health_state, :hard)
      end

    became_unhealthy_at =
      if new_status == :unhealthy and is_nil(health_state.became_unhealthy_at),
        do: DateTime.utc_now(),
        else: health_state.became_unhealthy_at

    %{
      health_state
      | failures: failures,
        consecutive_hard_failures: consecutive_hard_failures,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: new_status,
        backoff_ms: new_backoff,
        last_error_class: :hard,
        became_unhealthy_at: became_unhealthy_at
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
    case {old_state.last_check_at, old_state.status, new_state.status} do
      # Initial check that fails
      {nil, _old_status, :unhealthy} ->
        {:initial_failure, nil, :unhealthy}

      # Initial check that's healthy or degraded (no action needed)
      {nil, _old_status, status} when status != :unhealthy ->
        {:no_change, nil, status}

      # Transition to unhealthy
      {_last_check_at, old, :unhealthy} when old != :unhealthy ->
        {:became_unhealthy, old, :unhealthy}

      # Recovery to healthy (from unhealthy or degraded)
      {_last_check_at, old, :healthy} when old in [:unhealthy, :degraded] ->
        {:became_healthy, old, :healthy}

      # Degradation from healthy
      {_last_check_at, :healthy, :degraded} ->
        {:became_degraded, :healthy, :degraded}

      # No significant transition
      _other ->
        {:no_change, old_state.status, new_state.status}
    end
  end

  @doc """
  Builds a health report for all integrations belonging to a user.
  Reads current health state from the database.
  """
  @spec build_user_report(integer()) :: map()
  def build_user_report(user_id) do
    calendar_integrations = CalendarIntegrationQueries.list_all_for_user(user_id)
    video_integrations = VideoIntegrationQueries.list_all_for_user(user_id)

    calendar_health =
      Enum.map(calendar_integrations, fn integration ->
        health =
          case IntegrationHealthStateQueries.get(:calendar, integration.id) do
            {:ok, record} -> from_db_record(record)
            {:error, :not_found} -> initial_state()
          end

        %{
          id: integration.id,
          provider: integration.provider,
          is_active: integration.is_active,
          health: health
        }
      end)

    video_health =
      Enum.map(video_integrations, fn integration ->
        health =
          case IntegrationHealthStateQueries.get(:video, integration.id) do
            {:ok, record} -> from_db_record(record)
            {:error, :not_found} -> initial_state()
          end

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

  @doc """
  Converts a database record into a health_state map with atom values.
  """
  @spec from_db_record(IntegrationHealthStateSchema.t()) :: health_state()
  def from_db_record(%IntegrationHealthStateSchema{} = record) do
    %{
      user_id: record.user_id,
      failures: record.failures,
      consecutive_hard_failures: record.consecutive_hard_failures,
      successes: record.successes,
      last_check_at: record.last_check_at,
      status: safe_to_status(record.status),
      backoff_ms: record.backoff_ms,
      last_error_class: safe_to_error_class(record.last_error_class),
      became_unhealthy_at: record.became_unhealthy_at,
      notification_sent_at: record.notification_sent_at
    }
  end

  # Private Functions

  defp to_db_attrs(health_state) do
    base = %{
      status: Atom.to_string(health_state.status),
      failures: health_state.failures,
      consecutive_hard_failures: health_state.consecutive_hard_failures,
      successes: health_state.successes,
      backoff_ms: health_state.backoff_ms,
      last_check_at: health_state.last_check_at,
      last_error_class:
        health_state.last_error_class && Atom.to_string(health_state.last_error_class),
      became_unhealthy_at: health_state.became_unhealthy_at,
      notification_sent_at: health_state.notification_sent_at
    }

    case health_state[:user_id] do
      nil -> base
      user_id -> Map.put(base, :user_id, user_id)
    end
  end

  @valid_statuses ~w(healthy degraded unhealthy)a
  @statuses_by_name Map.new(@valid_statuses, &{Atom.to_string(&1), &1})

  defp safe_to_status(str) when is_binary(str),
    do: Map.get(@statuses_by_name, str, :degraded)

  @valid_error_classes ~w(transient hard)a
  @error_classes_by_name Map.new(@valid_error_classes, &{Atom.to_string(&1), &1})

  defp safe_to_error_class(nil), do: nil

  defp safe_to_error_class(str) when is_binary(str),
    do: Map.get(@error_classes_by_name, str, :hard)

  defp count_by_status(integration_lists, status) do
    integration_lists
    |> List.flatten()
    |> Enum.count(fn integration ->
      integration.health.status == status
    end)
  end
end
