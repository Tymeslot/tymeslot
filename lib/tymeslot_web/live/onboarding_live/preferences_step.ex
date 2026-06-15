defmodule TymeslotWeb.OnboardingLive.PreferencesStep do
  @moduledoc """
  Scheduling preference step components for the onboarding flow.

  Each preference (buffer time, booking window, minimum notice) is
  rendered as its own step with preset/custom toggle behaviour.
  """

  use Phoenix.Component

  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Renders the buffer time preference step.
  """
  attr :profile, :map, required: true
  attr :form_errors, :map, required: true

  attr :custom_input_mode, :map,
    default: %{buffer_minutes: false, advance_booking_days: false, min_advance_hours: false}

  @spec buffer_time_step(map()) :: Phoenix.LiveView.Rendered.t()
  def buffer_time_step(assigns) do
    ~H"""
    <form id="onboarding-buffer-time-form" phx-change="update_scheduling_preferences" phx-debounce="300" class="onboarding-form">
      <p class="onboarding-preference-example">
        If someone books you at 2:00 PM and your buffer is 15 min, the next available slot starts at 2:15 PM.
      </p>

      <div class="onboarding-preference-presets">
        <%= for {label, value} <- StepConfig.buffer_time_options() do %>
          <button
            type="button"
            phx-click="update_scheduling_preferences"
            phx-value-buffer_minutes={value}
            phx-value-_preset="true"
            class={[
              "btn-tag-selector btn-tag-selector-primary",
              if(@profile.buffer_minutes == value and
                   not Map.get(@custom_input_mode, :buffer_minutes, false),
                 do: "btn-tag-selector-primary--active"
              )
            ]}
          >
            {label}
          </button>
        <% end %>

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
        <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
      <% end %>
    </form>
    """
  end

  @doc """
  Renders the booking window preference step.
  """
  attr :profile, :map, required: true
  attr :form_errors, :map, required: true

  attr :custom_input_mode, :map,
    default: %{buffer_minutes: false, advance_booking_days: false, min_advance_hours: false}

  @spec booking_window_step(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_window_step(assigns) do
    ~H"""
    <form id="onboarding-booking-window-form" phx-change="update_scheduling_preferences" phx-debounce="300" class="onboarding-form">
      <p class="onboarding-preference-example">
        With a 2-week window, someone visiting your page today can only book up to 2 weeks ahead.
      </p>

      <div class="onboarding-preference-presets">
        <%= for {label, value} <- StepConfig.advance_booking_options() do %>
          <button
            type="button"
            phx-click="update_scheduling_preferences"
            phx-value-advance_booking_days={value}
            phx-value-_preset="true"
            class={[
              "btn-tag-selector btn-tag-selector-secondary",
              if(@profile.advance_booking_days == value and
                   not Map.get(@custom_input_mode, :advance_booking_days, false),
                 do: "btn-tag-selector-secondary--active"
              )
            ]}
          >
            {label}
          </button>
        <% end %>

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
        <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
      <% end %>
    </form>
    """
  end

  @doc """
  Renders the minimum notice preference step.
  """
  attr :profile, :map, required: true
  attr :form_errors, :map, required: true

  attr :custom_input_mode, :map,
    default: %{buffer_minutes: false, advance_booking_days: false, min_advance_hours: false}

  @spec minimum_notice_step(map()) :: Phoenix.LiveView.Rendered.t()
  def minimum_notice_step(assigns) do
    ~H"""
    <form id="onboarding-min-notice-form" phx-change="update_scheduling_preferences" phx-debounce="300" class="onboarding-form">
      <p class="onboarding-preference-example">
        With 3 hours' notice, nobody can book a slot that starts sooner than 3 hours from now.
      </p>

      <div class="onboarding-preference-presets">
        <%= for {label, value} <- StepConfig.min_advance_options() do %>
          <button
            type="button"
            phx-click="update_scheduling_preferences"
            phx-value-min_advance_hours={value}
            phx-value-_preset="true"
            class={[
              "btn-tag-selector btn-tag-selector-tertiary",
              if(@profile.min_advance_hours == value and
                   not Map.get(@custom_input_mode, :min_advance_hours, false),
                 do: "btn-tag-selector-tertiary--active"
              )
            ]}
          >
            {label}
          </button>
        <% end %>

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
        <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
      <% end %>
    </form>
    """
  end

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
