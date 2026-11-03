defmodule TymeslotWeb.OnboardingLive.ConnectCalendarStep do
  @moduledoc """
  The calendar step of the onboarding flow. A calendar is required: there is
  no skip, and Continue stays locked until the page is bookable.

  Each provider is a tile that acts when chosen: Google and Outlook go out to
  the provider's sign-in, Apple Calendar and other CalDAV servers open an
  inline form. Apple Calendar is its own tile, since hosts do not know iCloud
  speaks CalDAV. Connected calendars show as rows above the tiles, and a
  calendar that is connected but cannot take bookings gets a warning saying
  what to do.

  Three states:
  - `:selecting` - the tiles plus any connected calendars
  - `:connecting_apple` - the inline Apple Calendar form
  - `:connecting_caldav` - the inline CalDAV form
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents,
    only: [action_button: 1, icon: 1, info_box: 1, loading_button: 1]

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @own_tiles ~w(google outlook apple)

  @doc """
  Renders the calendar connection step.

  ## Attributes

  * `calendar_state` - `:selecting`, `:connecting_apple` or `:connecting_caldav`
  * `connected_calendars` - the host's calendar integrations
  * `booking_page_live` - whether the page can take bookings
  * `google_signup_email` - Google account email when the user signed up via
    Google (`nil` otherwise); surfaces the Recommended badge and one-click hint
  * `caldav_form_data` - the inline form's field values
  * `caldav_form_errors` - the inline form's validation errors
  """
  attr :calendar_state, :atom, required: true
  attr :connected_calendars, :list, required: true
  attr :booking_page_live, :boolean, default: false
  attr :google_signup_email, :string, default: nil
  attr :caldav_form_data, :map, required: true
  attr :caldav_form_errors, :map, required: true
  attr :caldav_discovering, :boolean, default: false

  @spec connect_calendar_step(map()) :: Phoenix.LiveView.Rendered.t()
  def connect_calendar_step(assigns) do
    connected = MapSet.new(assigns.connected_calendars, & &1.provider)

    assigns =
      assign(assigns,
        connected?: &tile_connected?(connected, &1),
        not_bookable?: assigns.connected_calendars != [] and assigns.booking_page_live != true
      )

    ~H"""
    <div>
      <%= case @calendar_state do %>
        <% :connecting_apple -> %>
          <.credentials_form
            provider={:apple}
            caldav_form_data={@caldav_form_data}
            caldav_form_errors={@caldav_form_errors}
            caldav_discovering={@caldav_discovering}
          />
        <% :connecting_caldav -> %>
          <.credentials_form
            provider={:caldav}
            caldav_form_data={@caldav_form_data}
            caldav_form_errors={@caldav_form_errors}
            caldav_discovering={@caldav_discovering}
          />
        <% _selecting -> %>
          <.info_box :if={@not_bookable?} variant={:warning} class="mb-4">
            <span data-role="calendar-not-bookable">
              {dgettext(
                "onboarding_wizard",
                "This calendar can't take bookings yet. Choose which calendar to check in Settings, or connect another."
              )}
            </span>
          </.info_box>

          <div class="onboarding-provider-cards">
            <.connected_row :for={calendar <- @connected_calendars} calendar={calendar} />

            <.provider_tile
              :if={not @connected?.("google")}
              option="google"
              name={dgettext("onboarding_wizard", "Google Calendar")}
              label={google_label(@google_signup_email)}
              recommended={@google_signup_email != nil}
            />

            <.provider_tile
              :if={not @connected?.("outlook")}
              option="outlook"
              name={dgettext("onboarding_wizard", "Outlook Calendar")}
              label={dgettext("onboarding_wizard", "Connect via Microsoft")}
            />

            <.provider_tile
              :if={not @connected?.("apple")}
              option="apple"
              name={dgettext("onboarding_wizard", "Apple Calendar")}
              label={dgettext("onboarding_wizard", "iCloud, on your iPhone or Mac")}
            />

            <.provider_tile
              :if={not @connected?.("caldav")}
              option="caldav"
              name={dgettext("onboarding_wizard", "Other calendar (CalDAV)")}
              label={dgettext("onboarding_wizard", "Nextcloud, Radicale, or any CalDAV server")}
            />
          </div>

          <p class="onboarding-privacy-line">
            <.icon name="hero-eye-slash-mini" class="w-4 h-4 shrink-0" />
            {dgettext(
              "onboarding_wizard",
              "We only read when you're busy, never what your events are."
            )}
          </p>
      <% end %>
    </div>
    """
  end

  # Google, Outlook and Apple each have a tile of their own; every other
  # CalDAV-family calendar counts as the CalDAV tile's.
  defp tile_connected?(connected, provider) when provider in @own_tiles,
    do: MapSet.member?(connected, provider)

  defp tile_connected?(connected, "caldav"),
    do: Enum.any?(connected, &(&1 not in @own_tiles))

  attr :option, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :recommended, :boolean, default: false

  defp provider_tile(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_calendar_option"
      phx-value-option={@option}
      class="onboarding-provider-card"
    >
      <span class="onboarding-provider-icon">
        <ProviderIcon.provider_icon provider={@option} type="calendar" size="medium" alt="" />
      </span>
      <span class="flex-1 min-w-0">
        <span class="flex items-center gap-2 flex-wrap">
          <span class="onboarding-provider-name">{@name}</span>
          <span :if={@recommended} class="onboarding-provider-badge">
            {dgettext("onboarding_wizard", "Recommended")}
          </span>
        </span>
        <span class="onboarding-provider-label block truncate">{@label}</span>
      </span>
      <.icon name="hero-chevron-right-mini" class="w-5 h-5 shrink-0 text-tymeslot-400" />
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
            provider: provider_name(@calendar.provider)
          )}
        </div>
      </div>
    </div>
    """
  end

  defp provider_name("apple"), do: dgettext("onboarding_wizard", "Apple Calendar")
  defp provider_name("caldav"), do: "CalDAV"
  defp provider_name(provider), do: String.capitalize(provider)

  defp google_label(nil), do: dgettext("onboarding_wizard", "Connect via Google")

  defp google_label(email),
    do: dgettext("onboarding_wizard", "One click - connect %{email}", email: email)

  attr :provider, :atom, required: true, values: [:apple, :caldav]
  attr :caldav_form_data, :map, required: true
  attr :caldav_form_errors, :map, required: true
  attr :caldav_discovering, :boolean, default: false

  # One form for both: Apple Calendar's server is fixed, so it asks only for
  # the Apple ID email and an app-specific password, with the dashboard's own
  # guidance on where to make one; a CalDAV server needs its address too.
  defp credentials_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:caldav}
      phx-change="validate_caldav"
      phx-submit="discover_caldav_calendars"
      class="onboarding-form"
      id={if @provider == :apple, do: "apple-form", else: "caldav-form"}
    >
      <div :if={@provider == :apple} class="flex items-center gap-3">
        <ProviderIcon.provider_icon provider="apple" type="calendar" size="medium" alt="" />
        <span class="onboarding-provider-name">
          {dgettext("onboarding_wizard", "Apple Calendar")}
        </span>
      </div>

      <SharedFormComponents.app_password_hint :if={@provider == :apple} provider={:apple} />

      <.credential_field
        :if={@provider == :caldav}
        id="caldav_url"
        name="url"
        label={dgettext("onboarding_wizard", "Server URL")}
        placeholder="https://cloud.example.com/remote.php/dav"
        form_data={@caldav_form_data}
        errors={@caldav_form_errors}
        error_key={:url}
      />

      <.credential_field
        id={"#{@provider}_username"}
        name="username"
        type={if @provider == :apple, do: "email", else: "text"}
        autocomplete="username"
        label={
          if @provider == :apple,
            do: dgettext("onboarding_wizard", "Apple ID email"),
            else: dgettext("onboarding_wizard", "Username")
        }
        placeholder={
          if @provider == :apple,
            do: "you@icloud.com",
            else: dgettext("onboarding_wizard", "your-username")
        }
        form_data={@caldav_form_data}
        errors={@caldav_form_errors}
        error_key={:username}
      />

      <.credential_field
        id={"#{@provider}_password"}
        name="password"
        type="password"
        autocomplete="off"
        label={
          if @provider == :apple,
            do: dgettext("onboarding_wizard", "App-specific password"),
            else: dgettext("onboarding_wizard", "Password")
        }
        placeholder={
          if @provider == :apple,
            do: "xxxx-xxxx-xxxx-xxxx",
            else: dgettext("onboarding_wizard", "App password or token")
        }
        form_data={@caldav_form_data}
        errors={@caldav_form_errors}
        error_key={:password}
      />

      <%= for message <- FormValidationHelpers.field_errors(@caldav_form_errors, :discovery) do %>
        <p class="text-token-sm text-red-600 font-bold">{message}</p>
      <% end %>

      <div class="flex gap-3">
        <.action_button
          variant={:secondary}
          phx-click="cancel_caldav"
          disabled={@caldav_discovering}
        >
          {dgettext("onboarding_wizard", "Cancel")}
        </.action_button>
        <.loading_button
          type="submit"
          class="flex-1"
          loading={@caldav_discovering}
          loading_text={dgettext("onboarding_wizard", "Discovering…")}
        >
          {if @provider == :apple,
            do: dgettext("onboarding_wizard", "Connect Apple Calendar"),
            else: dgettext("onboarding_wizard", "Discover calendars")}
        </.loading_button>
      </div>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, required: true
  attr :type, :string, default: "text"
  attr :autocomplete, :string, default: nil
  attr :form_data, :map, required: true
  attr :errors, :map, required: true
  attr :error_key, :atom, required: true

  defp credential_field(assigns) do
    assigns =
      assign(
        assigns,
        :messages,
        FormValidationHelpers.field_errors(assigns.errors, assigns.error_key)
      )

    ~H"""
    <div class="onboarding-form-group">
      <label for={@id} class="label">{@label}</label>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={Map.get(@form_data, @name, "")}
        autocomplete={@autocomplete}
        class={["input", @messages != [] && "input-error"]}
        placeholder={@placeholder}
      />
      <p :for={message <- @messages} class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
    </div>
    """
  end
end
