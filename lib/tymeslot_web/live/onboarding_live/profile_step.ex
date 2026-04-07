defmodule TymeslotWeb.OnboardingLive.ProfileStep do
  @moduledoc """
  Profile step component for the onboarding flow.

  Collects user profile information: full name, booking link username,
  and timezone selection.
  """

  use Phoenix.Component

  alias Tymeslot.Bookings.Policy
  alias TymeslotWeb.Components.TimezoneDropdown
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @doc """
  Renders the profile step form.

  ## Attributes

  * `profile` - The user's profile struct
  * `form_data` - Current form data map
  * `timezone_options` - Available timezone options
  * `timezone_dropdown_open` - Whether the timezone dropdown is open
  * `timezone_search` - Current timezone search query
  * `form_errors` - Map of form validation errors
  """
  attr :profile, :map, required: true
  attr :form_data, :map, required: true
  attr :timezone_options, :list, required: true
  attr :timezone_dropdown_open, :boolean, required: true
  attr :timezone_search, :string, required: true
  attr :form_errors, :map, required: true

  @spec profile_step(map()) :: Phoenix.LiveView.Rendered.t()
  def profile_step(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:basic_settings}
      phx-change="validate_basic_settings"
      phx-submit="update_basic_settings"
      class="onboarding-form"
      id="profile-form"
    >
      <%!-- Full name --%>
      <div class="onboarding-form-group">
        <label for="full_name" class="label">Your name</label>
        <p class="onboarding-form-helper">
          Shown on your booking page and in confirmations sent to clients.
        </p>
        <input
          type="text"
          id="full_name"
          name="full_name"
          value={Map.get(@form_data, "full_name", "")}
          class={[
            "input",
            if(FormValidationHelpers.field_errors(@form_errors, :full_name) != [],
              do: "input-error"
            )
          ]}
          placeholder="e.g. Jane Smith"
          autocomplete="name"
        />
        <%= for message <- FormValidationHelpers.field_errors(@form_errors, :full_name) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>

      <%!-- Username / booking link --%>
      <div class="onboarding-form-group">
        <label for="username" class="label">Your booking link</label>
        <p class="onboarding-form-helper">
          Share this link so people can book time with you. Choose something short and memorable.
        </p>
        <div class="relative group">
          <% base_url = Policy.app_url() %>
          <% display_url = String.replace(base_url, ~r/^https?:\/\//, "") %>
          <% padding_rem = (String.length(display_url) + 1) * 0.55 %>
          <div class="absolute inset-y-0 left-4 flex items-center pointer-events-none">
            <span class="text-tymeslot-400 font-bold text-token-sm tracking-tight">
              {display_url}/
            </span>
          </div>
          <input
            type="text"
            id="username"
            name="username"
            value={Map.get(@form_data, "username", "")}
            class={[
              "input",
              if(FormValidationHelpers.field_errors(@form_errors, :username) != [],
                do: "input-error"
              )
            ]}
            style={"padding-left: #{padding_rem}rem;"}
            placeholder="yourname"
            autocomplete="username"
          />
        </div>
        <%= for message <- FormValidationHelpers.field_errors(@form_errors, :username) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>

      <%!-- Timezone --%>
      <div class="onboarding-form-group">
        <label class="label">Your timezone</label>
        <p class="onboarding-form-helper">
          All your availability and bookings will be shown in this timezone.
        </p>
        <TimezoneDropdown.timezone_dropdown
          profile={@profile}
          timezone_options={@timezone_options}
          timezone_dropdown_open={@timezone_dropdown_open}
          timezone_search={@timezone_search}
          safe_flags={true}
        />
        <%= for message <- FormValidationHelpers.field_errors(@form_errors, :timezone) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>
    </.form>
    """
  end
end
