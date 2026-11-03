defmodule TymeslotWeb.OnboardingLive.ProfileStep do
  @moduledoc """
  The "Your link" step of the onboarding flow.

  Collects, in this order: the host's name, their booking link (suggested
  from the name until they type their own), an optional photo, and the
  timezone, shown as one line that opens the picker on request. Theme and
  colour selection live in their own, later `choose_theme` step.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [button_classes: 2, icon: 1]

  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Components.TimezoneDropdown
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @doc """
  Renders the profile step form.

  ## Attributes

  * `profile` - The user's profile struct (`nil` before the connected mount
    creates it on a first visit)
  * `form_data` - Current form data map
  * `timezone_options` - Available timezone options
  * `timezone_editing` - Whether the timezone picker replaces the timezone line
  * `timezone_dropdown_open` - Whether the timezone dropdown is open
  * `timezone_search` - Current timezone search query
  * `form_errors` - Map of form validation errors
  * `uploads` - The LiveView upload config map (must contain `:avatar`)
  * `avatar_url` - Resolved thumbnail URL for the current avatar
  """
  attr :profile, :map, required: true
  attr :form_data, :map, required: true
  attr :timezone_options, :list, required: true
  attr :timezone_editing, :boolean, default: false
  attr :timezone_dropdown_open, :boolean, required: true
  attr :timezone_search, :string, required: true
  attr :form_errors, :map, required: true
  attr :uploads, :map, required: true
  attr :avatar_url, :string, default: nil

  @spec profile_step(map()) :: Phoenix.LiveView.Rendered.t()
  def profile_step(assigns) do
    assigns =
      assign(assigns, :link_host, String.replace(UrlBuilder.base_url(), ~r{^https?://}, ""))

    ~H"""
    <div class="onboarding-form">
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
            phx-debounce="300"
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

        <%!-- Booking link: the host is a fixed prefix, the username follows --%>
        <div class="onboarding-form-group">
          <label for="username" class="label">{dgettext("onboarding_wizard", "Your booking link")}</label>
          <div class="relative">
            <div class="absolute inset-y-0 left-4 flex items-center pointer-events-none">
              <span class="text-tymeslot-400 font-bold text-token-sm tracking-tight">
                {@link_host}/
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
              style={"padding-left: #{String.length(@link_host) + 2}ch;"}
              placeholder={dgettext("onboarding_wizard", "yourname")}
              autocomplete="username"
              autocapitalize="none"
              autocorrect="off"
              spellcheck="false"
            />
          </div>
          <%= for message <- FormValidationHelpers.field_errors(@form_errors, :username) do %>
            <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
          <% end %>
        </div>
      </.form>

      <%!-- Photo, optional --%>
      <div id="onboarding-avatar-upload-group" class="onboarding-form-group" phx-hook="AutoUpload">
        <span class="label">{dgettext("onboarding_wizard", "Photo (optional)")}</span>
        <p class="onboarding-form-helper">
          {dgettext(
            "onboarding_wizard",
            "Shown on your page and in link previews when you share it."
          )}
        </p>
        <form
          id="onboarding-avatar-form"
          phx-change="validate_avatar"
          phx-drop-target={@uploads.avatar.ref}
          class="flex items-center gap-4 mt-1"
        >
          <div class="w-12 h-12 rounded-token-xl overflow-hidden bg-tymeslot-100 border border-tymeslot-200 shrink-0">
            <img src={@avatar_url} alt="" class="w-full h-full object-cover" />
          </div>
          <label for={@uploads.avatar.ref} class={button_classes(:secondary, :sm)}>
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
              else: dgettext("onboarding_wizard", "Uploading… %{percent}%", percent: entry.progress)}
          </p>
        <% end %>
        <%= for err <- upload_errors(@uploads.avatar) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">
            {Phoenix.Naming.humanize(err)}
          </p>
        <% end %>
      </div>

      <%!-- Timezone: one line, detected on mount, the picker on request --%>
      <div class="onboarding-form-group">
        <p
          :if={!@timezone_editing}
          data-role="timezone-line"
          class="flex flex-wrap items-center gap-x-2 gap-y-1 text-token-sm text-tymeslot-600"
        >
          <.icon name="hero-clock" class="w-4 h-4 shrink-0 text-tymeslot-400" />
          <span>
            {dgettext("onboarding_wizard", "Times shown in %{zone}",
              zone: Timezones.format(Profiles.timezone(@profile))
            )}
          </span>
          <span aria-hidden="true">·</span>
          <button
            type="button"
            phx-click="edit_timezone"
            aria-label={dgettext("onboarding_wizard", "Change timezone")}
            class="font-semibold text-turquoise-700 underline underline-offset-2 hover:text-turquoise-800 rounded-token-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-turquoise-500"
          >
            {dgettext("onboarding_wizard", "Change")}
          </button>
        </p>
        <TimezoneDropdown.timezone_dropdown
          :if={@timezone_editing}
          profile={@profile}
          timezone_options={@timezone_options}
          timezone_dropdown_open={@timezone_dropdown_open}
          timezone_search={@timezone_search}
          safe_flags={true}
          show_help={false}
          position={:bottom_start}
        />
        <%= for message <- FormValidationHelpers.field_errors(@form_errors, :timezone) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>
    </div>
    """
  end
end
