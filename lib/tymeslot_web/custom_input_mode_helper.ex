defmodule TymeslotWeb.CustomInputModeHelper do
  @moduledoc """
  Helper module for managing custom input mode state across scheduling preference components.

  Custom input mode tracks whether a user is in "custom value" mode (showing a text input)
  or "preset mode" (showing preset buttons) for scheduling preference fields.

  ## Fields

  The three scheduling preference fields that support custom input mode:
  - `:buffer_minutes` - Time buffer between appointments
  - `:advance_booking_days` - How far in advance bookings are allowed
  - `:min_advance_hours` - Minimum notice required for booking

  ## Security

  This module verifies that values marked as presets are actually in the preset list
  to prevent client-side manipulation of the custom input mode state.
  """

  alias Phoenix.Component
  alias TymeslotWeb.OnboardingLive.StepConfig

  @default_custom_mode %{
    buffer_minutes: false,
    advance_booking_days: false,
    min_advance_hours: false
  }

  @doc """
  Returns the default custom input mode state.

  All fields default to `false`, meaning preset mode is active.
  """
  @spec default_custom_mode() :: %{
          buffer_minutes: boolean(),
          advance_booking_days: boolean(),
          min_advance_hours: boolean()
        }
  def default_custom_mode, do: @default_custom_mode

  @doc """
  Updates custom input mode based on whether the update came from a preset button or custom input.

  When a preset button is clicked (indicated by `_preset` key in params), custom mode is disabled
  for that field. When a custom input changes (no `_preset` marker), custom mode remains active.

  ## Security

  Verifies that values with the `_preset` marker are actually in the preset list to prevent
  client-side manipulation.

  ## Parameters

  - `socket` - The LiveView socket
  - `field` - The field atom (`:buffer_minutes`, `:advance_booking_days`, or `:min_advance_hours`)
  - `params` - The event parameters from the client
  - `value` - The submitted value (for verification)

  ## Returns

  Updated socket with custom_input_mode assigned.

  ## Examples

      # Preset button clicked - disable custom mode
      socket = toggle_custom_mode(socket, :buffer_minutes, %{"_preset" => "true", "buffer_minutes" => "15"}, 15)

      # Custom input changed - keep custom mode active
      socket = toggle_custom_mode(socket, :buffer_minutes, %{"buffer_minutes" => "20"}, 20)
  """
  @spec toggle_custom_mode(Phoenix.LiveView.Socket.t(), atom(), map(), integer() | nil) ::
          Phoenix.LiveView.Socket.t()
  def toggle_custom_mode(socket, field, params, value) do
    current_custom_mode = Map.get(socket.assigns, :custom_input_mode, @default_custom_mode)

    custom_input_mode =
      if Map.has_key?(params, "_preset") do
        # This claims to be a preset click - verify it's actually a preset value
        if preset_value?(field, value) do
          # Valid preset - disable custom mode for this field
          Map.put(current_custom_mode, field, false)
        else
          # Security: client sent _preset marker with non-preset value - ignore and keep current state
          current_custom_mode
        end
      else
        # This is a custom input change - keep custom mode as is (it's already enabled)
        current_custom_mode
      end

    Component.assign(socket, :custom_input_mode, custom_input_mode)
  end

  @doc """
  Enables custom input mode for a specific field.

  Used when the "Custom" button is clicked to show the custom input field.

  ## Parameters

  - `socket` - The LiveView socket
  - `field` - The field atom to enable custom mode for

  ## Returns

  Updated socket with custom_input_mode assigned.

  ## Examples

      socket = enable_custom_mode(socket, :buffer_minutes)
  """
  @spec enable_custom_mode(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def enable_custom_mode(socket, field) do
    current_custom_mode = Map.get(socket.assigns, :custom_input_mode, @default_custom_mode)
    custom_input_mode = Map.put(current_custom_mode, field, true)
    Component.assign(socket, :custom_input_mode, custom_input_mode)
  end

  @doc """
  Checks if a value is in the preset list for a given field.

  ## Parameters

  - `field` - The field atom
  - `value` - The value to check

  ## Returns

  `true` if the value is a preset, `false` otherwise.

  ## Examples

      iex> preset_value?(:buffer_minutes, 15)
      true

      iex> preset_value?(:buffer_minutes, 20)
      false
  """
  @spec preset_value?(atom(), integer() | nil) :: boolean()
  def preset_value?(field, value) when is_integer(value) do
    preset_values =
      case field do
        :buffer_minutes -> StepConfig.buffer_time_values()
        :advance_booking_days -> StepConfig.advance_booking_values()
        :min_advance_hours -> StepConfig.min_advance_values()
        _other -> []
      end

    value in preset_values
  end

  def preset_value?(_field, _value), do: false
end
