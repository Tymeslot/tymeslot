defmodule TymeslotWeb.Dashboard.Automation.WebhookFormComponent do
  @moduledoc """
  Component for creating and editing webhooks.
  Displays a full-page form similar to theme customization.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Webhooks
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})
     |> assign(:saving, false)
     |> assign(:available_events, Webhooks.available_events())}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    mode = assigns[:mode] || :create
    webhook = assigns[:webhook]

    # Use form_values from assigns if provided (from parent),
    # otherwise initialize from webhook or defaults
    form_values =
      cond do
        Map.has_key?(assigns, :form_values) ->
          assigns.form_values

        mode == :edit && webhook ->
          %{
            "name" => webhook.name,
            "url" => webhook.url,
            "events" => webhook.events
          }

        true ->
          %{
            "name" => "",
            "url" => "",
            "events" => []
          }
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:mode, mode)
     |> assign(:webhook, webhook)
     |> assign(:form_values, form_values)
     |> assign(:form_errors, assigns[:form_errors] || %{})}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :can_submit, can_submit?(assigns))

    ~H"""
    <div class="space-y-8 pb-20">
      <%!-- Toolbar --%>
      <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-6 mb-10">
        <.section_header
          icon={:webhook}
          title={
            if @mode == :create,
              do: dgettext("dashboard_automation", "Create Webhook"),
              else: dgettext("dashboard_automation", "Edit Webhook")
          }
          class="mb-0"
        />

        <button
          phx-click="close_webhook_form"
          phx-target={@parent_component}
          class="flex items-center gap-2 px-5 py-2.5 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all border-2 border-transparent hover:border-tymeslot-200"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
          </svg>
          {dgettext("dashboard_automation", "Close")}
        </button>
      </div>

      <%!-- Form --%>
      <form
        id="webhook-form"
        phx-submit={
          if @mode == :create do
            JS.push("create_webhook", target: @parent_component)
          else
            JS.push("update_webhook", target: @parent_component)
          end
        }
        phx-target={@parent_component}
        class="space-y-8"
      >
        <%!-- Name Field --%>
        <div class="card-glass">
          <div class="mb-6">
            <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
              {dgettext("dashboard_automation", "Webhook Details")}
            </h3>
            <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
              {dgettext("dashboard_automation", "Configure the basic information for your webhook.")}
            </p>
          </div>

          <div class="space-y-6">
            <.input
              name="webhook[name]"
              label={dgettext("dashboard_automation", "Webhook Name")}
              value={Map.get(@form_values, "name", "")}
              phx-blur={JS.push("validate_field", value: %{"field" => "name"}, target: @parent_component)}
              placeholder={dgettext("dashboard_automation", "My n8n Automation")}
              required
              errors={FormValidationHelpers.field_errors(@form_errors, :name)}
              icon="hero-tag"
            />

            <.input
              name="webhook[url]"
              type="url"
              label={dgettext("dashboard_automation", "Webhook URL")}
              value={Map.get(@form_values, "url", "")}
              phx-blur={JS.push("validate_field", value: %{"field" => "url"}, target: @parent_component)}
              placeholder="https://your-n8n-instance.com/webhook/..."
              required
              errors={FormValidationHelpers.field_errors(@form_errors, :url)}
              icon="hero-link"
            />

            <div :if={@mode == :create} class="p-4 rounded-token-xl bg-turquoise-50/50 border-2 border-turquoise-100">
              <div class="flex gap-3">
                <div class="mt-0.5">
                  <svg class="w-5 h-5 text-turquoise-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                </div>
                <div>
                  <p class="text-token-sm font-black text-turquoise-900">
                    {dgettext("dashboard_automation", "Security Token")}
                  </p>
                  <p class="text-token-xs text-turquoise-700 font-medium mt-0.5">
                    {dgettext(
                      "dashboard_automation",
                      "A unique security token will be automatically generated for this webhook once created. You'll use it to verify requests in your automation tool."
                    )}
                  </p>
                </div>
              </div>
            </div>

            <div :if={@mode == :edit} class="space-y-2">
              <label class="block text-token-sm font-black text-tymeslot-900">
                {dgettext("dashboard_automation", "Security Token")}
                <span class="text-tymeslot-500 font-medium">
                  - {dgettext("dashboard_automation", "Use this in your n8n/Zapier header verification")}
                </span>
              </label>
              <div class="flex gap-2">
                <input
                  type="text"
                  value={@webhook.webhook_token}
                  readonly
                  class="font-mono text-token-sm flex-1 px-4 py-2.5 rounded-token-xl border-2 border-tymeslot-100 bg-tymeslot-50 text-tymeslot-600 cursor-default"
                  id="webhook_token_display"
                />
                <button
                  type="button"
                  id="copy-webhook-token"
                  phx-hook="CopyOnClick"
                  data-copy-text={@webhook.webhook_token}
                  data-copy-feedback={dgettext("dashboard_automation", "Security token copied to clipboard!")}
                  class="whitespace-nowrap px-5 py-2.5 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all border-2 border-transparent hover:border-tymeslot-200"
                >
                  {dgettext("dashboard_automation", "Copy")}
                </button>
                <button
                  type="button"
                  phx-click="show_regenerate_token_modal"
                  phx-value-id={@webhook.id}
                  phx-target={@parent_component}
                  class="whitespace-nowrap px-5 py-2.5 rounded-token-xl bg-red-50 text-red-600 font-bold hover:bg-red-100 transition-all border-2 border-transparent hover:border-red-200"
                >
                  {dgettext("dashboard_automation", "Regenerate")}
                </button>
              </div>
              <p class="text-token-xs text-tymeslot-500 font-medium">
                {raw(
                  dgettext(
                    "dashboard_automation",
                    "This token is automatically sent in the %{header} header.",
                    header: ~s(<code class="bg-tymeslot-100 px-1 rounded">X-Tymeslot-Token</code>)
                  )
                )}
              </p>
            </div>
          </div>
        </div>

        <%!-- Events Selection --%>
        <div class="card-glass">
          <div class="mb-6">
            <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
              {dgettext("dashboard_automation", "Event Subscriptions")}
            </h3>
            <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
              {dgettext("dashboard_automation", "Select which events should trigger this webhook.")}
            </p>
          </div>

          <div class="space-y-3">
            <%= for event <- @available_events do %>
              <label class="flex items-start gap-3 p-4 rounded-token-xl border-2 border-tymeslot-100 hover:border-turquoise-200 cursor-pointer transition-colors">
                <.input
                  type="checkbox"
                  name="webhook[events][]"
                  value={event.value}
                  checked={event.value in Map.get(@form_values, "events", [])}
                  phx-click={JS.push("toggle_event", value: %{"event" => event.value}, target: @parent_component)}
                />
                <div class="flex-1">
                  <div class="font-black text-tymeslot-900"><%= event.label %></div>
                  <div class="text-token-sm text-tymeslot-600 font-medium"><%= event.description %></div>
                </div>
              </label>
            <% end %>
          </div>
          <%= for error <- FormValidationHelpers.field_errors(@form_errors, :events) do %>
            <p class="text-token-sm text-red-600 font-medium mt-3"><%= error %></p>
          <% end %>
        </div>

        <%!-- Form Actions --%>
        <div class="flex justify-end gap-3 pt-4">
          <CoreComponents.action_button
            variant={:secondary}
            phx-click="close_webhook_form"
            phx-target={@parent_component}
          >
            {dgettext("dashboard_automation", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.loading_button
            type="submit"
            variant={:primary}
            loading={@saving}
            loading_text={dgettext("dashboard_automation", "Saving...")}
            disabled={!@can_submit}
            class={if !@can_submit, do: "opacity-50 cursor-not-allowed grayscale", else: ""}
            title={if !@can_submit, do: get_disabled_reason(assigns), else: ""}
          >
            <%= if @mode == :create,
              do: dgettext("dashboard_automation", "Create Webhook"),
              else: dgettext("dashboard_automation", "Update Webhook") %>
          </CoreComponents.loading_button>
        </div>
      </form>
    </div>
    """
  end

  defp can_submit?(assigns) do
    values = assigns.form_values
    errors = assigns.form_errors

    AutomationHelpers.field_present?(values, "name") &&
      AutomationHelpers.field_present?(values, "url") &&
      AutomationHelpers.any_events_selected?(values) &&
      Enum.empty?(errors)
  end

  defp get_disabled_reason(assigns) do
    values = assigns.form_values
    errors = assigns.form_errors

    cond do
      !Enum.empty?(errors) ->
        dgettext("dashboard_automation", "Please fix the validation errors above.")

      String.trim(Map.get(values, "name", "")) == "" ->
        dgettext("dashboard_automation", "Webhook name is required.")

      String.trim(Map.get(values, "url", "")) == "" ->
        dgettext("dashboard_automation", "Webhook URL is required.")

      !Enum.any?(Map.get(values, "events", [])) ->
        dgettext("dashboard_automation", "At least one event subscription is required.")

      true ->
        ""
    end
  end
end
