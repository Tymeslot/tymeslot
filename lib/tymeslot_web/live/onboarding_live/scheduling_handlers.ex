defmodule TymeslotWeb.OnboardingLive.SchedulingHandlers do
  @moduledoc """
  Scheduling preferences event handlers for the onboarding flow.

  Handles validation and updates for scheduling preferences including
  buffer time, advance booking window, and minimum advance notice.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles.Settings

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
        # Then update the profile with sanitized data
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

  defp validate_scheduling_preferences(params) do
    errors =
      [
        {"buffer_minutes", :buffer_minutes, &validate_buffer_minutes/1},
        {"advance_booking_days", :advance_booking_days, &validate_advance_booking_days/1},
        {"min_advance_hours", :min_advance_hours, &validate_min_advance_hours/1}
      ]
      |> Enum.flat_map(fn {key, error_key, validator} ->
        with {:ok, value} <- Map.fetch(params, key),
             {:error, error} <- validator.(value) do
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

  defp validate_buffer_minutes(value) when is_binary(value) do
    case Integer.parse(value) do
      {minutes, ""} -> validate_buffer_minutes(minutes)
      _other -> {:error, "Buffer minutes must be a valid number"}
    end
  end

  defp validate_buffer_minutes(minutes) when is_integer(minutes) do
    if minutes >= 0 and minutes <= 120,
      do: :ok,
      else: {:error, "Buffer minutes must be between 0 and 120"}
  end

  defp validate_buffer_minutes(_invalid), do: {:error, "Buffer minutes must be a number"}

  defp validate_advance_booking_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} -> validate_advance_booking_days(days)
      _other -> {:error, "Advance booking days must be a valid number"}
    end
  end

  defp validate_advance_booking_days(days) when is_integer(days) do
    if days >= 1 and days <= 365,
      do: :ok,
      else: {:error, "Advance booking days must be between 1 and 365"}
  end

  defp validate_advance_booking_days(_invalid), do: {:error, "Advance booking days must be a number"}

  defp validate_min_advance_hours(value) when is_binary(value) do
    case Integer.parse(value) do
      {hours, ""} -> validate_min_advance_hours(hours)
      _other -> {:error, "Minimum advance hours must be a valid number"}
    end
  end

  defp validate_min_advance_hours(hours) when is_integer(hours) do
    if hours >= 0 and hours <= 168,
      do: :ok,
      else: {:error, "Minimum advance hours must be between 0 and 168"}
  end

  defp validate_min_advance_hours(_invalid), do: {:error, "Minimum advance hours must be a number"}
end
