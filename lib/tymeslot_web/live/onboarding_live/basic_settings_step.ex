defmodule TymeslotWeb.OnboardingLive.BasicSettingsStep do
  @moduledoc """
  Basic settings step component for the onboarding flow.

  Handles the collection of user profile information including
  full name, username, and timezone selection.
  """

  use Phoenix.Component

  alias TymeslotWeb.Components.TimezoneDropdown

  @doc """
  Renders the basic settings step component.

  ## Assigns

  * `profile` - The user's profile struct
  * `form_data` - Current form data map
  * `timezone_options` - Available timezone options
  * `timezone_dropdown_open` - Boolean for dropdown state
  * `timezone_search` - Current search query
  * `form_errors` - Map of form validation errors
  """
  @spec basic_settings_step(map()) :: Phoenix.LiveView.Rendered.t()
  def basic_settings_step(assigns) do
    ~H"""
    <div>
      <div class="text-center mb-6">
        <h2 class="onboarding-step-title">Basic Settings</h2>
        <p class="onboarding-step-description">Let's personalize your account</p>
      </div>

      <.form
        for={%{}}
        as={:basic_settings}
        phx-change="validate_basic_settings"
        phx-submit="update_basic_settings"
        class="onboarding-form"
        id="basic-settings-form"
      >
        <div class="onboarding-form-group">
          <label for="full_name" class="onboarding-form-label">
            Full Name
          </label>
          <input
            type="text"
            id="full_name"
            name="full_name"
            value={Map.get(@form_data, "full_name", "")}
            class={[
              "onboarding-form-input glass-input",
              if(@form_errors[:full_name], do: "border-red-500", else: "")
            ]}
            placeholder="Enter your full name"
            autocomplete="name"
          />
          <%= if @form_errors[:full_name] do %>
            <p class="mt-1 text-sm text-red-600">{@form_errors[:full_name]}</p>
          <% end %>
        </div>

        <div class="onboarding-form-group">
          <label for="username" class="onboarding-form-label">
            Username
          </label>
          <input
            type="text"
            id="username"
            name="username"
            value={Map.get(@form_data, "username", "")}
            class={[
              "onboarding-form-input glass-input",
              if(@form_errors[:username], do: "border-red-500", else: "")
            ]}
            placeholder="Choose a username"
            autocomplete="username"
          />
          <%= if @form_errors[:username] do %>
            <p class="mt-1 text-sm text-red-600">{@form_errors[:username]}</p>
          <% end %>
          <p class="text-sm mt-1 font-medium" style="color: var(--color-text-glass-secondary);">
            This will be your public scheduling URL: {Application.get_env(:tymeslot, :email)[:domain] || "tymeslot.app"}/{Map.get(
              @form_data,
              "username",
              "username"
            )}
          </p>
        </div>

    <!-- Timezone component inside form -->
        <div class="onboarding-form-group">
          <TimezoneDropdown.timezone_dropdown
            profile={@profile}
            timezone_options={@timezone_options}
            timezone_dropdown_open={@timezone_dropdown_open}
            timezone_search={@timezone_search}
            safe_flags={true}
          />
          <%= if @form_errors[:timezone] do %>
            <p class="mt-1 text-sm text-red-600">{@form_errors[:timezone]}</p>
          <% end %>
        </div>
      </.form>
    </div>
    """
  end
end
