defmodule TymeslotWeb.OnboardingLive.SchedulingHandlers do
  @moduledoc """
  Scheduling preferences event handlers for the onboarding flow.

  Handles validation and updates for scheduling preferences including
  buffer time, advance booking window, and minimum advance notice.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles.Settings
  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Handles validation of scheduling preferences.

  Validates scheduling preference input in real-time.
  """
  @spec handle_validate_scheduling_preferences(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_scheduling_preferences(params, socket) do
    case validate_scheduling_preferences(params) do
      {:ok, _sanitized_params} ->
        {:noreply, Component.assign(socket, :form_errors, %{})}

      {:error, errors} ->
        {:noreply, Component.assign(socket, :form_errors, errors)}
    end
  end

  @doc """
  Handles updating scheduling preferences in the database.

  Validates and persists scheduling preference settings.
  """
  @spec handle_update_scheduling_preferences(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_scheduling_preferences(params, socket) do
    case validate_scheduling_preferences(params) do
      {:ok, sanitized_params} ->
        case Settings.update_scheduling_preferences(
               socket.assigns.profile,
               sanitized_params
             ) do
          {:ok, profile} ->
            socket =
              socket
              |> Component.assign(:profile, profile)
              |> Component.assign(:form_errors, %{})

            {:noreply, socket}

          {:error, _changeset} ->
            {:noreply,
             LiveView.put_flash(socket, :error, "Please check your input and try again.")}
        end

      {:error, errors} ->
        socket = Component.assign(socket, :form_errors, errors)

        {:noreply, socket}
    end
  end

  # Private helpers

  @fields [
    {"buffer_minutes", :buffer_minutes, "Buffer minutes"},
    {"advance_booking_days", :advance_booking_days, "Advance booking days"},
    {"min_advance_hours", :min_advance_hours, "Minimum advance hours"}
  ]

  defp validate_scheduling_preferences(params) do
    config = StepConfig.custom_input_config()

    errors =
      @fields
      |> Enum.flat_map(fn {key, error_key, label} ->
        with {:ok, value} <- Map.fetch(params, key),
             {:error, error} <- validate_field(value, config[key].constraints, label) do
          [{error_key, error}]
        else
          :error -> []
          :ok -> []
          {:ok, _value} -> []
        end
      end)
      |> Map.new()

    if map_size(errors) == 0, do: {:ok, params}, else: {:error, errors}
  end

  defp validate_field(value, constraints, label) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> validate_field(int, constraints, label)
      _other -> {:error, "#{label} must be a valid number"}
    end
  end

  defp validate_field(value, %{min: min, max: max}, label) when is_integer(value) do
    if value >= min and value <= max,
      do: :ok,
      else: {:error, "#{label} must be between #{min} and #{max}"}
  end

  defp validate_field(_value, _constraints, label), do: {:error, "#{label} must be a number"}
end
