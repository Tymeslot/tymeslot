defmodule TymeslotWeb.OnboardingLive.ConnectCalendarStep do
  @moduledoc """
  The calendar step of the onboarding flow. A calendar is required: there is
  no skip, and Continue stays locked until the page is bookable.

  Each provider is a tile that acts when chosen: Google and Outlook go out to
  the provider's sign-in, Apple Calendar and other CalDAV servers open an
  inline form. Apple Calendar is its own tile, since hosts do not know iCloud
  speaks CalDAV. Connected calendars show as rows above the tiles.

  A paused calendar (switched off, or waiting for its credentials again)
  cannot take bookings, so its row says so and offers to reconnect it, its
  provider's tile stays available, and while nothing is bookable a warning
  says what to do. The warning has no link to the dashboard's settings: the
  dashboard sends a host who has not finished setup back here.

  Three states:
  - `:selecting` - the tiles plus any connected calendars
  - `:connecting_apple` - the inline Apple Calendar form
  - `:connecting_caldav` - the inline CalDAV form
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents,
    only: [action_button: 1, icon: 1, info_box: 1, input: 1, loading_button: 1]

  alias TymeslotWeb.Components.CoreComponents.Forms
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
  * `reconnecting` - whether the inline form reconnects a paused calendar
  """
  attr :calendar_state, :atom, required: true
  attr :connected_calendars, :list, required: true
  attr :booking_page_live, :boolean, default: false
  attr :google_signup_email, :string, default: nil
  attr :caldav_form_data, :map, required: true
  attr :caldav_form_errors, :map, required: true
  attr :caldav_discovering, :boolean, default: false
  attr :reconnecting, :boolean, default: false

  @spec connect_calendar_step(map()) :: Phoenix.LiveView.Rendered.t()
  def connect_calendar_step(assigns) do
    connected =
      for calendar <- assigns.connected_calendars, not paused?(calendar), into: MapSet.new() do
        calendar.provider
      end

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
            reconnecting={@reconnecting}
            caldav_form_data={@caldav_form_data}
            caldav_form_errors={@caldav_form_errors}
            caldav_discovering={@caldav_discovering}
          />
        <% :connecting_caldav -> %>
          <.credentials_form
            provider={:caldav}
            reconnecting={@reconnecting}
            caldav_form_data={@caldav_form_data}
            caldav_form_errors={@caldav_form_errors}
            caldav_discovering={@caldav_discovering}
          />
        <% _selecting -> %>
          <.info_box :if={@not_bookable?} variant={:warning} class="mb-4">
            <span data-role="calendar-not-bookable">
              {dgettext(
                "onboarding_wizard",
                "This calendar is paused, so it can't take bookings. Reconnect it or connect another."
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

  # Switched off, or waiting for its credentials again: either way it takes
  # no bookings until the host reconnects it.
  defp paused?(%{is_active: false}), do: true
  defp paused?(%{needs_reauth: true}), do: true
  defp paused?(_calendar), do: false

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
    assigns = assign(assigns, :paused, paused?(assigns.calendar))

    ~H"""
    <div
      class={[
        "onboarding-connected-calendar",
        @paused && "onboarding-connected-calendar--paused"
      ]}
      data-calendar-state={if @paused, do: "paused", else: "connected"}
    >
      <.icon
        :if={not @paused}
        name="hero-check-circle-solid"
        class="w-5 h-5 text-green-600 shrink-0"
      />
      <.icon
        :if={@paused}
        name="hero-exclamation-triangle-mini"
        class="w-5 h-5 text-amber-600 shrink-0"
      />
      <div class="flex-1 min-w-0">
        <div class="text-token-base font-bold text-tymeslot-800 truncate">
          {@calendar.provider_account_email || @calendar.name}
        </div>
        <div class="text-token-sm text-tymeslot-500">
          {if @paused,
            do:
              dgettext("onboarding_wizard", "%{provider} · Paused",
                provider: provider_name(@calendar.provider)
              ),
            else:
              dgettext("onboarding_wizard", "%{provider} · Connected",
                provider: provider_name(@calendar.provider)
              )}
        </div>
      </div>
      <.action_button
        :if={@paused}
        variant={:secondary}
        size={:sm}
        phx-click="reconnect_calendar"
        phx-value-id={@calendar.id}
      >
        {dgettext("onboarding_wizard", "Reconnect")}
      </.action_button>
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
  attr :reconnecting, :boolean, default: false
  attr :caldav_form_data, :map, required: true
  attr :caldav_form_errors, :map, required: true
  attr :caldav_discovering, :boolean, default: false

  # One form for both: Apple Calendar's server is fixed, so it asks only for
  # the Apple ID email and an app-specific password, with the dashboard's own
  # guidance on where to make one; a CalDAV server needs its address too.
  # Reconnecting a paused calendar fills in what is known and takes a new
  # password.
  defp credentials_form(assigns) do
    assigns =
      assign(assigns,
        apple?: assigns.provider == :apple,
        errors: &FormValidationHelpers.field_errors(assigns.caldav_form_errors, &1),
        value: &Map.get(assigns.caldav_form_data, &1, "")
      )

    ~H"""
    <.form
      for={%{}}
      as={:caldav}
      phx-change="validate_caldav"
      phx-submit="discover_caldav_calendars"
      class="onboarding-form"
      id={if @apple?, do: "apple-form", else: "caldav-form"}
    >
      <div :if={@apple?} class="flex items-center gap-3">
        <ProviderIcon.provider_icon provider="apple" type="calendar" size="medium" alt="" />
        <span class="onboarding-provider-name">
          {dgettext("onboarding_wizard", "Apple Calendar")}
        </span>
      </div>

      <SharedFormComponents.app_password_hint
        :if={@apple?}
        provider={:apple}
        reconnecting={@reconnecting}
      />

      <.input
        :if={not @apple?}
        id="caldav_url"
        name="url"
        value={@value.("url")}
        label={dgettext("onboarding_wizard", "Server URL")}
        placeholder="https://cloud.example.com/remote.php/dav"
        errors={@errors.(:url)}
      />

      <.input
        id={"#{@provider}_username"}
        name="username"
        type={if @apple?, do: "email", else: "text"}
        value={@value.("username")}
        label={
          if @apple?,
            do: dgettext("onboarding_wizard", "Apple ID email"),
            else: dgettext("onboarding_wizard", "Username")
        }
        placeholder={
          if @apple?,
            do: "you@icloud.com",
            else: dgettext("onboarding_wizard", "your-username")
        }
        errors={@errors.(:username)}
      />

      <.input
        id={"#{@provider}_password"}
        name="password"
        type="password"
        value={@value.("password")}
        label={
          if @apple?,
            do: dgettext("onboarding_wizard", "App-specific password"),
            else: dgettext("onboarding_wizard", "Password")
        }
        placeholder={
          if @apple?,
            do: "xxxx-xxxx-xxxx-xxxx",
            else: dgettext("onboarding_wizard", "App password or token")
        }
        errors={@errors.(:password)}
      />

      <Forms.field_error id="calendar-form-error" errors={@errors.(:discovery)} />

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
          {submit_label(@provider, @reconnecting)}
        </.loading_button>
      </div>
    </.form>
    """
  end

  defp submit_label(_provider, true), do: dgettext("onboarding_wizard", "Reconnect")
  defp submit_label(:apple, false), do: dgettext("onboarding_wizard", "Connect Apple Calendar")
  defp submit_label(:caldav, false), do: dgettext("onboarding_wizard", "Discover calendars")
end
