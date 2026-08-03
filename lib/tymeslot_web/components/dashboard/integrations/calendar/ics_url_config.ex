defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.IcsUrlConfig do
  @moduledoc """
  Configuration form for subscribing to a published calendar feed.

  Deliberately not built on the shared CalDAV `config_form/1`: that form is a
  two-step credentials-then-discovery flow, and a subscription has neither
  step. One name, one URL, one button.
  """

  use TymeslotWeb, :live_component

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @default_name "My subscribed calendar"

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:default_name, @default_name)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"ics-url-config-#{@id}"} class="space-y-6">
      <div class="flex items-center gap-4">
        <ProviderIcon.provider_icon provider="ics_url" type="calendar" size="large" />
        <div>
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">Calendar subscription</h3>
          <p class="text-sm text-tymeslot-500 font-medium">
            Subscribe to a published calendar feed
          </p>
        </div>
      </div>

      <form
        id="calendar-subscription-form"
        phx-submit="add_subscription"
        phx-change="track_form_change"
        phx-target={@target}
        class="space-y-5"
      >
        <input type="hidden" name="integration[provider]" value="ics_url" />

        <p class="text-sm text-tymeslot-500">
          Paste the feed link your calendar gives you when you publish a calendar: Google's
          secret address in iCal format, Outlook's published calendar link, or any
          <span class="font-mono">.ics</span>
          URL. We check it for busy time only, and never write to it.
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
            label="Feed URL"
            value={Map.get(@form_values, "url", "")}
            placeholder="https://outlook.office365.com/owa/calendar/.../calendar.ics"
            errors={FormValidationHelpers.field_errors(@form_errors, :url)}
            target={@target}
            field="url"
            icon="hero-link"
          />
        </div>

        <.info_box variant={:info}>
          This calendar stays read-only: it blocks the times you're already busy, and
          bookings are never written to it. Choose another calendar as your booking
          destination.
        </.info_box>

        <SharedForm.error_banner
          :for={error <- FormValidationHelpers.field_errors(@form_errors, :generic)}
          error={error}
        />

        <div class="flex justify-between items-center pt-4 border-t border-turquoise-200/30">
          <UIComponents.secondary_button target={@target} />
          <UIComponents.form_submit_button
            saving={@saving}
            text="Subscribe"
            saving_text="Subscribing..."
          />
        </div>
      </form>
    </div>
    """
  end
end
