defmodule TymeslotWeb.OnboardingLive.SchedulingPreferencesStep do
  @moduledoc """
  Scheduling preferences step component for the onboarding flow.

  Handles the configuration of scheduling preferences including
  buffer time, advance booking window, and minimum advance notice.
  """

  use Phoenix.Component

  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Renders the scheduling preferences step component.

  ## Assigns

  * `profile` - The user's profile struct
  * `form_errors` - Map of form validation errors
  """
  @spec scheduling_preferences_step(map()) :: Phoenix.LiveView.Rendered.t()
  def scheduling_preferences_step(assigns) do
    ~H"""
    <div>
      <div class="text-center mb-6">
        <h2 class="onboarding-step-title">Scheduling Preferences</h2>
        <p class="onboarding-step-description">Configure your default meeting settings</p>
      </div>

      <div class="onboarding-form space-y-6">
        <!-- Buffer Time Between Meetings -->
        <div class="onboarding-form-group">
          <label class="onboarding-form-label">
            Buffer Time Between Meetings
          </label>

          <div class="flex flex-wrap items-center gap-2">
            <%= for {label, value} <- StepConfig.buffer_time_options() do %>
              <button
                type="button"
                phx-click="update_scheduling_preferences"
                phx-value-buffer_minutes={value}
                class={[
                  "inline-flex items-center px-3 py-2 rounded-full text-sm font-medium transition-all duration-200",
                  if(@profile.buffer_minutes == value,
                    do: "bg-teal-100 text-teal-800 border border-teal-300",
                    else: "bg-gray-100 text-gray-700 border border-gray-300 hover:bg-gray-200"
                  )
                ]}
              >
                {label}
              </button>
            <% end %>
          </div>

          <p class="text-sm mt-2 font-medium" style="color: var(--color-text-glass-secondary);">
            Time to block before and after each meeting
          </p>
          <%= if @form_errors[:buffer_minutes] do %>
            <p class="mt-1 text-sm text-red-600">{@form_errors[:buffer_minutes]}</p>
          <% end %>
        </div>
        
    <!-- Advance Booking Window -->
        <div class="onboarding-form-group">
          <label class="onboarding-form-label">
            Advance Booking Window
          </label>

          <div class="flex flex-wrap items-center gap-2">
            <%= for {label, value} <- StepConfig.advance_booking_options() do %>
              <button
                type="button"
                phx-click="update_scheduling_preferences"
                phx-value-advance_booking_days={value}
                class={[
                  "inline-flex items-center px-3 py-2 rounded-full text-sm font-medium transition-all duration-200",
                  if(@profile.advance_booking_days == value,
                    do: "bg-blue-100 text-blue-800 border border-blue-300",
                    else: "bg-gray-100 text-gray-700 border border-gray-300 hover:bg-gray-200"
                  )
                ]}
              >
                {label}
              </button>
            <% end %>
          </div>

          <p class="text-sm mt-2 font-medium" style="color: var(--color-text-glass-secondary);">
            How far in advance people can book meetings
          </p>
          <%= if @form_errors[:advance_booking_days] do %>
            <p class="mt-1 text-sm text-red-600">{@form_errors[:advance_booking_days]}</p>
          <% end %>
        </div>
        
    <!-- Minimum Advance Notice -->
        <div class="onboarding-form-group">
          <label class="onboarding-form-label">
            Minimum Advance Notice
          </label>

          <div class="flex flex-wrap items-center gap-2">
            <%= for {label, value} <- StepConfig.min_advance_options() do %>
              <button
                type="button"
                phx-click="update_scheduling_preferences"
                phx-value-min_advance_hours={value}
                class={[
                  "inline-flex items-center px-3 py-2 rounded-full text-sm font-medium transition-all duration-200",
                  if(@profile.min_advance_hours == value,
                    do: "bg-purple-100 text-purple-800 border border-purple-300",
                    else: "bg-gray-100 text-gray-700 border border-gray-300 hover:bg-gray-200"
                  )
                ]}
              >
                {label}
              </button>
            <% end %>
          </div>

          <p class="text-sm mt-2 font-medium" style="color: var(--color-text-glass-secondary);">
            Minimum time required before a meeting can be booked
          </p>
          <%= if @form_errors[:min_advance_hours] do %>
            <p class="mt-1 text-sm text-red-600">{@form_errors[:min_advance_hours]}</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
