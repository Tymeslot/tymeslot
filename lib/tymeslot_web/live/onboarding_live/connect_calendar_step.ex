defmodule TymeslotWeb.OnboardingLive.ConnectCalendarStep do
  @moduledoc """
  Calendar connection step component for the onboarding flow.

  Forced-choice model: the user selects exactly one option — a calendar
  provider or "Not right now" — and nothing connects until they press
  Continue. Already-connected calendars render as read-only "connected" rows.

  Two states:
  - `:selecting` — provider/opt-out choices plus any connected calendars
  - `:connecting_caldav` — inline CalDAV credential form
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @doc """
  Renders the calendar connection step.

  ## Attributes

  * `calendar_state` - Current state atom (`:selecting` or `:connecting_caldav`)
  * `connected_calendars` - List of connected calendar integrations
  * `calendar_choice` - The currently selected option (`"google"`, `"outlook"`,
    `"caldav"`, `"skip"`) or `nil` when nothing is selected yet
  * `google_signup_email` - Google account email when the user signed up via
    Google (`nil` otherwise); surfaces the Recommended badge and one-click hint
  * `caldav_form_data` - CalDAV form field values
  * `caldav_form_errors` - CalDAV form validation errors
  """
  attr :calendar_state, :atom, required: true
  attr :connected_calendars, :list, required: true
  attr :calendar_choice, :string, default: nil
  attr :google_signup_email, :string, default: nil
  attr :caldav_form_data, :map, required: true
  attr :caldav_form_errors, :map, required: true
  attr :caldav_discovering, :boolean, default: false

  @spec connect_calendar_step(map()) :: Phoenix.LiveView.Rendered.t()
  def connect_calendar_step(assigns) do
    connected_providers = Enum.map(assigns.connected_calendars, & &1.provider)

    assigns =
      assigns
      |> assign(:google_connected?, "google" in connected_providers)
      |> assign(:outlook_connected?, "outlook" in connected_providers)
      |> assign(
        :caldav_connected?,
        Enum.any?(connected_providers, &(&1 not in ["google", "outlook"]))
      )

    ~H"""
    <div>
      <%= if @calendar_state == :connecting_caldav do %>
        <.caldav_form
          caldav_form_data={@caldav_form_data}
          caldav_form_errors={@caldav_form_errors}
          caldav_discovering={@caldav_discovering}
        />
      <% else %>
        <div class="onboarding-provider-cards">
          <%= for calendar <- @connected_calendars do %>
            <.connected_row calendar={calendar} />
          <% end %>

          <.choice_card
            :if={not @google_connected?}
            option="google"
            selected={@calendar_choice == "google"}
            icon="hero-calendar-days"
            icon_class="bg-blue-50 text-blue-600"
            name={dgettext("onboarding_wizard", "Google Calendar")}
            label={google_label(@google_signup_email)}
            recommended={@google_signup_email != nil}
          />

          <.choice_card
            :if={not @outlook_connected?}
            option="outlook"
            selected={@calendar_choice == "outlook"}
            icon="hero-calendar"
            icon_class="bg-cyan-50 text-cyan-600"
            name={dgettext("onboarding_wizard", "Outlook Calendar")}
            label={dgettext("onboarding_wizard", "Connect via Microsoft")}
          />

          <.choice_card
            :if={not @caldav_connected?}
            option="caldav"
            selected={@calendar_choice == "caldav"}
            icon="hero-server"
            icon_class="bg-tymeslot-100 text-tymeslot-600"
            name="CalDAV"
            label={dgettext("onboarding_wizard", "Nextcloud, Radicale, or any CalDAV server")}
          />

          <.choice_card
            :if={@connected_calendars == []}
            option="skip"
            selected={@calendar_choice == "skip"}
            icon="hero-clock"
            icon_class="bg-tymeslot-50 text-tymeslot-500"
            name={dgettext("onboarding_wizard", "Not right now")}
            label={dgettext("onboarding_wizard", "I'll connect a calendar later")}
          />
        </div>
      <% end %>
    </div>
    """
  end

  attr :option, :string, required: true
  attr :selected, :boolean, default: false
  attr :icon, :string, required: true
  attr :icon_class, :string, default: ""
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :recommended, :boolean, default: false

  defp choice_card(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_calendar_option"
      phx-value-option={@option}
      aria-pressed={to_string(@selected)}
      class={[
        "onboarding-provider-card onboarding-choice-card",
        @selected && "onboarding-choice-card--selected"
      ]}
    >
      <div class={[
        "onboarding-provider-icon flex items-center justify-center rounded-lg",
        @icon_class
      ]}>
        <.icon name={@icon} class="w-5 h-5" />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <div class="onboarding-provider-name">{@name}</div>
          <span :if={@recommended} class="onboarding-provider-badge">
            {dgettext("onboarding_wizard", "Recommended")}
          </span>
        </div>
        <div class="onboarding-provider-label truncate">{@label}</div>
      </div>
      <span class={[
        "onboarding-choice-radio",
        @selected && "onboarding-choice-radio--selected"
      ]}>
        <.icon :if={@selected} name="hero-check-mini" class="w-3.5 h-3.5 text-white" />
      </span>
    </button>
    """
  end

  attr :calendar, :map, required: true

  defp connected_row(assigns) do
    ~H"""
    <div class="onboarding-connected-calendar">
      <.icon name="hero-check-circle-solid" class="w-5 h-5 text-green-600 shrink-0" />
      <div class="flex-1 min-w-0">
        <div class="text-token-base font-bold text-tymeslot-800 truncate">
          {@calendar.provider_account_email || @calendar.name}
        </div>
        <div class="text-token-sm text-tymeslot-400">
          {dgettext("onboarding_wizard", "%{provider} · Connected",
            provider: String.capitalize(@calendar.provider)
          )}
        </div>
      </div>
    </div>
    """
  end

  defp google_label(nil), do: dgettext("onboarding_wizard", "Connect via Google")

  defp google_label(email),
    do: dgettext("onboarding_wizard", "One click - connect %{email}", email: email)

  defp caldav_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:caldav}
      phx-change="validate_caldav"
      phx-submit="discover_caldav_calendars"
      class="onboarding-form"
      id="caldav-form"
    >
      <div class="onboarding-form-group">
        <label for="caldav_url" class="label">{dgettext("onboarding_wizard", "Server URL")}</label>
        <input
          type="text"
          id="caldav_url"
          name="url"
          value={Map.get(@caldav_form_data, "url", "")}
          class={[
            "input",
            if(FormValidationHelpers.field_errors(@caldav_form_errors, :url) != [],
              do: "input-error"
            )
          ]}
          placeholder="https://cloud.example.com/remote.php/dav"
        />
        <%= for message <- FormValidationHelpers.field_errors(@caldav_form_errors, :url) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>

      <div class="onboarding-form-group">
        <label for="caldav_username" class="label">{dgettext("onboarding_wizard", "Username")}</label>
        <input
          type="text"
          id="caldav_username"
          name="username"
          value={Map.get(@caldav_form_data, "username", "")}
          class={[
            "input",
            if(FormValidationHelpers.field_errors(@caldav_form_errors, :username) != [],
              do: "input-error"
            )
          ]}
          placeholder={dgettext("onboarding_wizard", "your-username")}
        />
        <%= for message <- FormValidationHelpers.field_errors(@caldav_form_errors, :username) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>

      <div class="onboarding-form-group">
        <label for="caldav_password" class="label">{dgettext("onboarding_wizard", "Password")}</label>
        <input
          type="password"
          id="caldav_password"
          name="password"
          value={Map.get(@caldav_form_data, "password", "")}
          class={[
            "input",
            if(FormValidationHelpers.field_errors(@caldav_form_errors, :password) != [],
              do: "input-error"
            )
          ]}
          placeholder={dgettext("onboarding_wizard", "App password or token")}
        />
        <%= for message <- FormValidationHelpers.field_errors(@caldav_form_errors, :password) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>

      <%= for message <- FormValidationHelpers.field_errors(@caldav_form_errors, :discovery) do %>
        <p class="text-token-sm text-red-600 font-bold">{message}</p>
      <% end %>

      <div class="flex gap-3">
        <button
          type="button"
          phx-click="cancel_caldav"
          class="btn-secondary px-5 py-2.5"
          disabled={@caldav_discovering}
        >
          {dgettext("onboarding_wizard", "Cancel")}
        </button>
        <button
          type="submit"
          class="btn-primary px-5 py-2.5 flex-1 flex items-center justify-center gap-2"
          disabled={@caldav_discovering}
        >
          <.icon :if={@caldav_discovering} name="hero-arrow-path" class="w-5 h-5 animate-spin" />
          {if @caldav_discovering,
            do: dgettext("onboarding_wizard", "Discovering…"),
            else: dgettext("onboarding_wizard", "Discover calendars")}
        </button>
      </div>
    </.form>
    """
  end
end
