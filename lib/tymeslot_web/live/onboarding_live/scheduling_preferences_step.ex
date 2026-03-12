defmodule TymeslotWeb.OnboardingLive.SchedulingPreferencesStep do
  @moduledoc """
  Scheduling preferences step component for the onboarding flow.

  Handles the configuration of scheduling preferences including
  buffer time, advance booking window, and minimum advance notice.
  """

  use Phoenix.Component

  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Renders the scheduling preferences step component.

  ## Assigns

  * `profile` - The user's profile struct
  * `form_errors` - Map of form validation errors
  """
  attr :profile, :map, required: true
  attr :form_errors, :map, required: true

  attr :custom_input_mode, :map,
    default: %{buffer_minutes: false, advance_booking_days: false, min_advance_hours: false}

  @spec scheduling_preferences_step(map()) :: Phoenix.LiveView.Rendered.t()
  def scheduling_preferences_step(assigns) do
    # Ensure custom_input_mode exists with defaults
    assigns =
      assign_new(assigns, :custom_input_mode, fn ->
        %{
          buffer_minutes: false,
          advance_booking_days: false,
          min_advance_hours: false
        }
      end)

    ~H"""
    <div class="onboarding-step">
      <div class="text-center mb-6">
        <h2 class="onboarding-step-title">{StepConfig.step_title(:scheduling_preferences)}</h2>
        <p class="onboarding-step-description">{StepConfig.step_description(:scheduling_preferences)}</p>
      </div>

      <form phx-change="update_scheduling_preferences" phx-debounce="300" class="onboarding-form text-left">
        <!-- Buffer Time Between Meetings -->
        <div class="onboarding-form-group">
          <label class="label">
            Buffer Between Meetings
          </label>

          <p class="text-sm mb-3 font-bold text-tymeslot-400 uppercase tracking-widest">
            Time to block after every appointment
          </p>

          <div class="flex flex-wrap items-center gap-3">
            <%= for {label, value} <- StepConfig.buffer_time_options() do %>
              <button
                type="button"
                phx-click="update_scheduling_preferences"
                phx-value-buffer_minutes={value}
                phx-value-_preset="true"
                class={[
                  "btn-tag-selector btn-tag-selector-primary",
                  if(@profile.buffer_minutes == value and not Map.get(@custom_input_mode, :buffer_minutes, false),
                    do: "btn-tag-selector-primary--active"
                  )
                ]}
              >
                {label}
              </button>
            <% end %>

            <!-- Custom input or "Custom" button -->
            <.custom_input_toggle
              field_name="buffer_minutes"
              current_value={@profile.buffer_minutes}
              preset_values={StepConfig.buffer_time_values()}
              constraints={StepConfig.buffer_minutes_constraints()}
              style_variant="primary"
              custom_mode={Map.get(@custom_input_mode, :buffer_minutes, false)}
            />
          </div>

          <%= for message <- FormValidationHelpers.field_errors(@form_errors, :buffer_minutes) do %>
            <p class="mt-2 text-sm text-red-600 font-bold">{message}</p>
          <% end %>
        </div>

    <!-- Advance Booking Window -->
        <div class="onboarding-form-group pt-6 border-t-2 border-tymeslot-50">
          <label class="label">
            Booking Window
          </label>

          <p class="text-sm mb-3 font-bold text-tymeslot-400 uppercase tracking-widest">
            How far in advance clients can schedule
          </p>

          <div class="flex flex-wrap items-center gap-3">
            <%= for {label, value} <- StepConfig.advance_booking_options() do %>
              <button
                type="button"
                phx-click="update_scheduling_preferences"
                phx-value-advance_booking_days={value}
                phx-value-_preset="true"
                class={[
                  "btn-tag-selector btn-tag-selector-secondary",
                  if(@profile.advance_booking_days == value and not Map.get(@custom_input_mode, :advance_booking_days, false),
                    do: "btn-tag-selector-secondary--active"
                  )
                ]}
              >
                {label}
              </button>
            <% end %>

            <!-- Custom input or "Custom" button -->
            <.custom_input_toggle
              field_name="advance_booking_days"
              current_value={@profile.advance_booking_days}
              preset_values={StepConfig.advance_booking_values()}
              constraints={StepConfig.advance_booking_constraints()}
              style_variant="secondary"
              custom_mode={Map.get(@custom_input_mode, :advance_booking_days, false)}
            />
          </div>

          <%= for message <- FormValidationHelpers.field_errors(@form_errors, :advance_booking_days) do %>
            <p class="mt-2 text-sm text-red-600 font-bold">{message}</p>
          <% end %>
        </div>

    <!-- Minimum Advance Notice -->
        <div class="onboarding-form-group pt-6 border-t-2 border-tymeslot-50">
          <label class="label">
            Minimum Notice
          </label>

          <p class="text-sm mb-3 font-bold text-tymeslot-400 uppercase tracking-widest">
            Prevents last-minute surprise bookings
          </p>

          <div class="flex flex-wrap items-center gap-3">
            <%= for {label, value} <- StepConfig.min_advance_options() do %>
              <button
                type="button"
                phx-click="update_scheduling_preferences"
                phx-value-min_advance_hours={value}
                phx-value-_preset="true"
                class={[
                  "btn-tag-selector btn-tag-selector-tertiary",
                  if(@profile.min_advance_hours == value and not Map.get(@custom_input_mode, :min_advance_hours, false),
                    do: "btn-tag-selector-tertiary--active"
                  )
                ]}
              >
                {label}
              </button>
            <% end %>

            <!-- Custom input or "Custom" button -->
            <.custom_input_toggle
              field_name="min_advance_hours"
              current_value={@profile.min_advance_hours}
              preset_values={StepConfig.min_advance_values()}
              constraints={StepConfig.min_advance_constraints()}
              style_variant="tertiary"
              custom_mode={Map.get(@custom_input_mode, :min_advance_hours, false)}
            />
          </div>

          <%= for message <- FormValidationHelpers.field_errors(@form_errors, :min_advance_hours) do %>
            <p class="mt-2 text-sm text-red-600 font-bold">{message}</p>
          <% end %>
        </div>
      </form>
    </div>
    """
  end

  # Renders a custom input toggle component for scheduling preferences.
  #
  # Shows either:
  # - A custom number input with unit label when in custom mode or current value is not in presets
  # - A "Custom" button when not in custom mode and current value matches a preset
  #
  # ## Attributes
  #
  # * `field_name` - The field name (e.g., "buffer_minutes")
  # * `current_value` - The current field value
  # * `preset_values` - List of preset values
  # * `constraints` - Map with min, max, step, unit, and color configuration
  # * `style_variant` - Button style variant (primary, secondary, tertiary)
  # * `custom_mode` - Whether custom input mode is active for this field
  attr :field_name, :string, required: true
  attr :current_value, :integer, required: true
  attr :preset_values, :list, required: true
  attr :constraints, :map, required: true
  attr :style_variant, :string, required: true
  attr :custom_mode, :boolean, required: true

  defp custom_input_toggle(assigns) do
    ~H"""
    <%= if @custom_mode or @current_value not in @preset_values do %>
      <div class={"btn-tag-selector btn-tag-selector-#{@style_variant}--active !p-0 overflow-hidden"}>
        <input
          type="number"
          min={@constraints.min}
          max={@constraints.max}
          step={@constraints.step}
          value={@current_value}
          name={@field_name}
          class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-none rounded-l-xl"
          placeholder={to_string(@constraints.min)}
        />
        <span class={"pr-3 py-2 text-token-sm font-black text-#{@constraints.color}-700"}>
          {@constraints.unit}
        </span>
      </div>
    <% else %>
      <button
        type="button"
        phx-click="focus_custom_input"
        phx-value-setting={@field_name}
        class={"btn-tag-selector btn-tag-selector-#{@style_variant}"}
      >
        Custom
      </button>
    <% end %>
    """
  end
end
