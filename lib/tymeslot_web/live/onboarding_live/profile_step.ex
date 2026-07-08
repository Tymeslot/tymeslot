defmodule TymeslotWeb.OnboardingLive.ProfileStep do
  @moduledoc """
  Profile step component for the onboarding flow.

  Collects user profile information: photo, full name, booking link username,
  and timezone selection. Theme and colour selection live in their own,
  later `choose_theme` step (shown once a calendar is connected).
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

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
  * `uploads` - The LiveView upload config map (must contain `:avatar`)
  * `avatar_url` - Resolved thumbnail URL for the current avatar
  """
  attr :profile, :map, required: true
  attr :form_data, :map, required: true
  attr :timezone_options, :list, required: true
  attr :timezone_dropdown_open, :boolean, required: true
  attr :timezone_search, :string, required: true
  attr :form_errors, :map, required: true
  attr :uploads, :map, required: true
  attr :avatar_url, :string, default: nil

  @spec profile_step(map()) :: Phoenix.LiveView.Rendered.t()
  def profile_step(assigns) do
    ~H"""
    <div class="onboarding-form">
      <%!-- Avatar upload --%>
      <div class="onboarding-form-group">
        <label class="label">{dgettext("onboarding_wizard", "Your photo")}</label>
        <p class="onboarding-form-helper">
          {dgettext(
            "onboarding_wizard",
            "A friendly face helps invitees recognise who they're booking with."
          )}
        </p>
        <form
          id="onboarding-avatar-form"
          phx-change="validate_avatar"
          phx-drop-target={@uploads.avatar.ref}
          class="flex items-center gap-4"
        >
          <div class="w-16 h-16 rounded-token-2xl overflow-hidden bg-tymeslot-100 border border-tymeslot-200 shrink-0">
            <img src={@avatar_url} alt="" class="w-full h-full object-cover" />
          </div>
          <label
            for={@uploads.avatar.ref}
            class="btn-secondary px-4 py-2 inline-flex items-center gap-2 cursor-pointer whitespace-nowrap"
          >
            <.icon name="hero-arrow-up-tray-mini" class="w-4 h-4 shrink-0" />
            <span>
              {if @profile && @profile.avatar,
                do: dgettext("onboarding_wizard", "Change photo"),
                else: dgettext("onboarding_wizard", "Upload photo")}
            </span>
            <.live_file_input upload={@uploads.avatar} class="sr-only" />
          </label>
        </form>
        <%= for entry <- @uploads.avatar.entries do %>
          <p class="mt-2 text-token-sm text-tymeslot-500 font-medium">
            {if entry.progress == 100,
              do: dgettext("onboarding_wizard", "Processing…"),
              else:
                dgettext("onboarding_wizard", "Uploading… %{percent}%", percent: entry.progress)}
          </p>
        <% end %>
        <%= for err <- upload_errors(@uploads.avatar) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">
            {Phoenix.Naming.humanize(err)}
          </p>
        <% end %>
      </div>

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
          <label for="full_name" class="label">{dgettext("onboarding_wizard", "Your name")}</label>
          <p class="onboarding-form-helper">
            {dgettext(
              "onboarding_wizard",
              "Shown on your booking page and in confirmations sent to clients."
            )}
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
            placeholder={dgettext("onboarding_wizard", "e.g. Jane Smith")}
            autocomplete="name"
          />
          <%= for message <- FormValidationHelpers.field_errors(@form_errors, :full_name) do %>
            <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
          <% end %>
        </div>

        <%!-- Username / booking link --%>
        <div class="onboarding-form-group">
          <label for="username" class="label">{dgettext("onboarding_wizard", "Your booking link")}</label>
          <p class="onboarding-form-helper">
            {dgettext(
              "onboarding_wizard",
              "Share this link so people can book time with you. Choose something short and memorable."
            )}
          </p>
          <div class="relative group">
            <% base_url = Policy.app_url() %>
            <% display_url = String.replace(base_url, ~r/^https?:\/\//, "") %>
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
              style={"padding-left: #{String.length(display_url) + 2}ch;"}
              placeholder={dgettext("onboarding_wizard", "yourname")}
              autocomplete="username"
            />
          </div>
          <%= for message <- FormValidationHelpers.field_errors(@form_errors, :username) do %>
            <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
          <% end %>
        </div>

        <%!-- Timezone --%>
        <div class="onboarding-form-group">
          <label class="label">{dgettext("onboarding_wizard", "Your timezone")}</label>
          <p class="onboarding-form-helper">
            {dgettext(
              "onboarding_wizard",
              "All your availability and bookings will be shown in this timezone."
            )}
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
    </div>
    """
  end
end
