defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.IcsUrlConfig do
  @moduledoc """
  Configuration form for subscribing to a published calendar feed.

  Deliberately not built on the shared CalDAV `config_form/1`: that form is a
  two-step credentials-then-discovery flow, and a subscription has neither
  step. One name, one URL, one button.
  """

  use TymeslotWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Integrations.Calendar.InputValidation, as: CalendarInputValidation

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @default_name "My subscribed calendar"

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:default_name, @default_name)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("track_form_change", %{"integration" => params}, socket) do
    {:noreply, assign(socket, :form_values, params)}
  end

  def handle_event("validate_field", %{"field" => field} = params, socket) do
    form_values = socket.assigns.form_values || %{}
    value = params["integration"][field] || form_values[field] || ""
    field_atom = if field == "url", do: :url, else: :name

    if String.trim(to_string(value)) == "" do
      {:noreply, clear_error(socket, field_atom)}
    else
      case CalendarInputValidation.validate_single_field(field_atom, value,
             metadata: socket.assigns.metadata
           ) do
        {:ok, _sanitized} ->
          {:noreply, clear_error(socket, field_atom)}

        {:error, error} ->
          {:noreply,
           assign(socket, :form_errors, Map.put(socket.assigns.form_errors, field_atom, error))}
      end
    end
  end

  defp clear_error(socket, field_atom) do
    assign(
      socket,
      :form_errors,
      FormValidationHelpers.delete_field_error(socket.assigns.form_errors, field_atom)
    )
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"ics-url-config-#{@id}"} class="space-y-6">
      <div class="flex items-start justify-between gap-4 mb-2">
        <div class="flex items-center gap-4">
          <ProviderIcon.provider_icon provider="ics_url" type="calendar" size="large" />
          <div>
            <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">Calendar subscription</h3>
            <p class="text-sm text-tymeslot-500 font-medium">
              Subscribe to a published calendar feed
            </p>
          </div>
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

          <.input
            id="subscription_url"
            name="integration[url]"
            type="text"
            label="Feed URL"
            value={Map.get(@form_values, "url", "")}
            required
            phx-blur={JS.push("validate_field", value: %{"field" => "url"}, target: @target)}
            placeholder="https://outlook.office365.com/owa/calendar/.../calendar.ics"
            errors={FormValidationHelpers.field_errors(@form_errors, :url)}
            icon="hero-link"
          />
        </div>

        <.info_box variant={:info} class="mb-0">
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
