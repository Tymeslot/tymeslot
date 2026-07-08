defmodule TymeslotWeb.OnboardingLive.SchedulingHandlers do
  @moduledoc """
  Scheduling preferences event handlers for the onboarding flow.

  Handles validation and updates for scheduling preferences including
  buffer time, advance booking window, and minimum advance notice.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles.Settings
  alias TymeslotWeb.CustomInputModeHelper
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
             LiveView.put_flash(
               socket,
               :error,
               dgettext("onboarding_wizard", "Please check your input and try again.")
             )}
        end

      {:error, errors} ->
        socket = Component.assign(socket, :form_errors, errors)

        {:noreply, socket}
    end
  end

  @doc """
  Updates scheduling preferences and, on success, syncs the per-field
  custom-input modes from the submitted params. Combines the persistence step
  with its custom-input bookkeeping so the LiveView delegates a single call.
  """
  @spec handle_update_with_custom_modes(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_with_custom_modes(params, socket) do
    {:noreply, updated_socket} = handle_update_scheduling_preferences(params, socket)

    if Map.get(updated_socket.assigns, :form_errors, %{}) == %{} do
      {:noreply, update_custom_input_modes(updated_socket, params)}
    else
      {:noreply, updated_socket}
    end
  end

  @doc """
  Seeds and reveals the custom-value input for a scheduling field, switching it
  into custom mode (unless validation of the seeded value fails).
  """
  @spec handle_focus_custom_input(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_focus_custom_input(setting, socket) do
    with %{} = config <- StepConfig.custom_input_config()[setting],
         %{} = profile <- socket.assigns[:profile] do
      current = Map.get(profile, config.field) || config.constraints.default_custom

      custom_value =
        if current in config.presets, do: config.constraints.default_custom, else: current

      params = %{setting => to_string(custom_value)}

      {:noreply, updated_socket} = handle_update_scheduling_preferences(params, socket)

      if Map.get(updated_socket.assigns, :form_errors, %{}) == %{} do
        {:noreply, CustomInputModeHelper.enable_custom_mode(updated_socket, config.field)}
      else
        {:noreply, updated_socket}
      end
    else
      _other -> {:noreply, socket}
    end
  end

  # Private helpers

  defp update_custom_input_modes(socket, params) do
    Enum.reduce(params, socket, fn {key, value}, acc ->
      field = field_key_to_atom(key)
      if field, do: try_update_mode(acc, field, value, params), else: acc
    end)
  end

  defp field_key_to_atom("buffer_minutes"), do: :buffer_minutes
  defp field_key_to_atom("advance_booking_days"), do: :advance_booking_days
  defp field_key_to_atom("min_advance_hours"), do: :min_advance_hours
  defp field_key_to_atom(_arg), do: nil

  defp try_update_mode(socket, field, value_str, params) when is_binary(value_str) do
    case Integer.parse(value_str) do
      {int_value, _value} ->
        CustomInputModeHelper.toggle_custom_mode(socket, field, params, int_value)

      _other ->
        socket
    end
  end

  defp try_update_mode(socket, _field, _value, _params), do: socket

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
        end
      end)
      |> Map.new()

    if map_size(errors) == 0, do: {:ok, params}, else: {:error, errors}
  end

  defp validate_field(value, constraints, label) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} ->
        validate_field(int, constraints, label)

      _other ->
        {:error, dgettext("onboarding_wizard", "%{field} must be a valid number", field: label)}
    end
  end

  defp validate_field(value, %{min: min, max: max}, label) when is_integer(value) do
    if value >= min and value <= max,
      do: :ok,
      else:
        {:error,
         dgettext(
           "onboarding_wizard",
           "%{field} must be between %{min} and %{max}",
           field: label,
           min: min,
           max: max
         )}
  end

  defp validate_field(_value, _constraints, label),
    do: {:error, dgettext("onboarding_wizard", "%{field} must be a number", field: label)}
end
