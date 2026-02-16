defmodule TymeslotWeb.OnboardingLive.BasicSettingsStep do
  @moduledoc """
  Basic settings step component for the onboarding flow.

  Handles the collection of user profile information including
  full name, username, and timezone selection.
  """

  use Phoenix.Component

  alias Tymeslot.Bookings.Policy
  alias TymeslotWeb.Components.TimezoneDropdown
  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  alias TymeslotWeb.OnboardingLive.StepConfig

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
  attr :profile, :map, required: true
  attr :form_data, :map, required: true
  attr :timezone_options, :list, required: true
  attr :timezone_dropdown_open, :boolean, required: true
  attr :timezone_search, :string, required: true
  attr :form_errors, :map, required: true

  @spec basic_settings_step(map()) :: Phoenix.LiveView.Rendered.t()
  def basic_settings_step(assigns) do
    ~H"""
    <div class="onboarding-step">
      <div class="text-center mb-6">
        <h2 class="onboarding-step-title">{StepConfig.step_title(:basic_settings)}</h2>
        <p class="onboarding-step-description">{StepConfig.step_description(:basic_settings)}</p>
      </div>

      <.form
        for={%{}}
        as={:basic_settings}
        phx-change="validate_basic_settings"
        phx-submit="update_basic_settings"
        class="onboarding-form text-left"
        id="basic-settings-form"
      >
        <div class="onboarding-form-group">
          <label for="full_name" class="label">
            Display Name
          </label>
          <input
            type="text"
            id="full_name"
            name="full_name"
            value={Map.get(@form_data, "full_name", "")}
            class={[
              "input",
              if(FormValidationHelpers.field_errors(@form_errors, :full_name) != [], do: "input-error", else: "")
            ]}
            placeholder="e.g. John Doe"
            autocomplete="name"
          />
          <%= for message <- FormValidationHelpers.field_errors(@form_errors, :full_name) do %>
            <p class="mt-2 text-sm text-red-600 font-bold">{message}</p>
          <% end %>
        </div>

        <div class="onboarding-form-group">
          <label for="username" class="label">
            Booking URL
          </label>
          <div class="relative group">
            <% base_url = Policy.app_url() %>
            <% display_url = String.replace(base_url, ~r/^https?:\/\//, "") %>
            <% # Calculate dynamic padding based on URL length (approximate: 0.6rem per character) %>
            <% padding_rem = (String.length(display_url) + 1) * 0.55 %>
            <div class="absolute inset-y-0 left-4 flex items-center pointer-events-none">
              <span class="text-slate-400 font-bold text-sm tracking-tight">{display_url}/</span>
            </div>
            <input
              type="text"
              id="username"
              name="username"
              value={Map.get(@form_data, "username", "")}
              class={[
                "input",
                if(FormValidationHelpers.field_errors(@form_errors, :username) != [], do: "input-error", else: "")
              ]}
              style={"padding-left: #{padding_rem}rem;"}
              placeholder="yourname"
              autocomplete="username"
            />
          </div>
          <%= for message <- FormValidationHelpers.field_errors(@form_errors, :username) do %>
            <p class="mt-2 text-sm text-red-600 font-bold">{message}</p>
          <% end %>
          <p class="text-sm mt-3 font-bold text-slate-400 uppercase tracking-widest">
            This will be your unique scheduling link.
          </p>
        </div>

    <!-- Timezone component inside form -->
        <div class="onboarding-form-group pt-3 border-t-2 border-slate-50">
          <label class="label mb-3">Your Timezone</label>
          <TimezoneDropdown.timezone_dropdown
            profile={@profile}
            timezone_options={@timezone_options}
            timezone_dropdown_open={@timezone_dropdown_open}
            timezone_search={@timezone_search}
            safe_flags={true}
          />
          <%= for message <- FormValidationHelpers.field_errors(@form_errors, :timezone) do %>
            <p class="mt-2 text-sm text-red-600 font-bold">{message}</p>
          <% end %>
        </div>
      </.form>
    </div>
    """
  end
end
