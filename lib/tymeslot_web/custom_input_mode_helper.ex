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

  @typedoc "A scheduling preference field that supports preset tags and custom input."
  @type field :: :buffer_minutes | :advance_booking_days | :min_advance_hours

  # The quick-pick values offered for each scheduling preference field, and the
  # only table of them. Every surface that renders preset tags — the onboarding
  # wizard's preference steps and the dashboard availability policy card —
  # builds its tags from this, and `preset_value?/2` validates a `_preset` click
  # against the same list. Rendering from a separate literal is what let the card
  # offer values the validator rejected, leaving it stuck in custom-input mode
  # after a legitimate preset click.
  #
  # Labels stay with each surface: onboarding and the dashboard word the same
  # value differently ("24 hours" vs "1 day") and translate in different gettext
  # domains. Only the values are shared.
  #
  # The lists are the union of what the two surfaces offered while they each
  # kept their own: neither was a superset of the other, and neither could be
  # taken as authoritative — the card's minimum-notice list did not even contain
  # 3, the schema's own default, so a new user's card opened in custom-input
  # mode. Unifying by union means no value stopped being offered anywhere.
  @presets %{
    buffer_minutes: [0, 5, 10, 15, 30, 45, 60],
    advance_booking_days: [7, 14, 30, 60, 90, 180, 365],
    min_advance_hours: [0, 1, 3, 4, 6, 12, 24, 48, 168]
  }

  @default_custom_mode Map.new(Map.keys(@presets), &{&1, false})

  @doc """
  Returns the fields that support custom input mode.
  """
  @spec fields() :: [field()]
  def fields, do: Map.keys(@presets)

  @doc """
  Returns the preset values offered for `field`.

  Raises for an unknown field rather than reporting it as having no presets: a
  field that reaches here is always one of this module's own, and a silent empty
  list would make every value look like client tampering.
  """
  @spec presets(field()) :: [non_neg_integer()]
  def presets(field), do: Map.fetch!(@presets, field)

  @doc """
  Returns the default custom input mode state.

  All fields default to `false`, meaning preset mode is active.
  """
  @spec default_custom_mode() :: %{field() => boolean()}
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
  @spec toggle_custom_mode(Phoenix.LiveView.Socket.t(), field(), map(), integer() | nil) ::
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
  @spec enable_custom_mode(Phoenix.LiveView.Socket.t(), field()) :: Phoenix.LiveView.Socket.t()
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
  @spec preset_value?(field(), integer() | nil) :: boolean()
  def preset_value?(field, value) when is_integer(value), do: value in presets(field)

  def preset_value?(_field, _value), do: false
end
