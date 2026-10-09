defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.IcsUrlConfig do
  @moduledoc """
  Configuration form for subscribing to a published calendar feed.

  Deliberately not built on the shared CalDAV `config_form/1`: that form is a
  two-step credentials-then-discovery flow, and a subscription has neither
  step. One name, one URL, one button.
  """

  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:default_name, default_name())}
  end

  # Resolved per render rather than held in a module attribute: a `dgettext/2`
  # call in an attribute would freeze the locale at compile time.
  defp default_name, do: dgettext("dashboard_calendar_providers", "My subscribed calendar")

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"ics-url-config-#{@id}"} class="space-y-6">
      <UIComponents.provider_config_header
        provider="ics_url"
        type="calendar"
        title={dgettext("dashboard_calendar_providers", "Calendar subscription")}
        tagline={dgettext("dashboard_calendar_providers", "Subscribe to a published calendar feed")}
      />

      <form
        id="calendar-subscription-form"
        phx-submit="add_subscription"
        phx-change="track_form_change"
        phx-target={@target}
        class="space-y-5"
      >
        <input type="hidden" name="integration[provider]" value="ics_url" />

        <p class="text-sm text-tymeslot-500">
          {dgettext(
            "dashboard_calendar_providers",
            "Paste the feed link your calendar gives you when you publish a calendar: Google's secret address in iCal format, Outlook's published calendar link, or any .ics URL. We check it for busy time only, and never write to it."
          )}
        </p>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <SharedForm.integration_name_field
            form_errors={@form_errors}
            suggested_name={Map.get(@form_values, "name", @default_name)}
            placeholder={@default_name}
            target={@target}
          />

          <SharedForm.text_field
            id="subscription_url"
            name="integration[url]"
            label={dgettext("dashboard_calendar_providers", "Feed URL")}
            value={Map.get(@form_values, "url", "")}
            placeholder="https://outlook.office365.com/owa/calendar/.../calendar.ics"
            errors={FormValidationHelpers.field_errors(@form_errors, :url)}
            target={@target}
            field="url"
            icon="hero-link"
          />
        </div>

        <label
          for="subscription_all_events_busy"
          class="flex items-start gap-3 p-4 rounded-token-xl border-2 border-tymeslot-100 hover:border-turquoise-200 cursor-pointer transition-colors"
        >
          <.input
            type="checkbox"
            id="subscription_all_events_busy"
            name="integration[all_events_busy]"
            value={Map.get(@form_values, "all_events_busy", "false")}
          />
          <div class="flex-1">
            <div class="font-bold text-tymeslot-900">
              {dgettext("dashboard_calendar_providers", "Count every event as busy")}
            </div>
            <div class="text-token-sm text-tymeslot-600 font-medium">
              {dgettext(
                "dashboard_calendar_providers",
                "Holiday and school-holiday calendars mark their events as free, so they would block nothing. With this on, every event in the feed blocks the time, however it is marked."
              )}
            </div>
          </div>
        </label>

        <.info_box variant={:info}>
          {dgettext(
            "dashboard_calendar_providers",
            "This calendar stays read-only: it blocks the times you're already busy, and bookings are never written to it. Choose another calendar as your booking destination."
          )}
        </.info_box>

        <SharedForm.error_banner
          :for={error <- FormValidationHelpers.field_errors(@form_errors, :generic)}
          error={error}
        />

        <UIComponents.form_actions
          target={@target}
          saving={@saving}
          class="border-turquoise-200/30"
          submit_text={dgettext("dashboard_calendar_providers", "Subscribe")}
          saving_text={dgettext("dashboard_calendar_providers", "Subscribing...")}
        />
      </form>
    </div>
    """
  end
end
