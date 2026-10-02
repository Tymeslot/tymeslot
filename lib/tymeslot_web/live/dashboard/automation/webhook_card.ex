defmodule TymeslotWeb.Dashboard.Automation.WebhookCard do
  @moduledoc """
  UI component for displaying a single webhook card.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Webhooks.DeliveryStatus
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Dashboard.Automation.Helpers

  attr :webhook, :map, required: true
  attr :time_format, :string, required: true
  attr :testing, :boolean, default: false
  attr :target, :any, required: true
  attr :on_edit, :any, required: true
  attr :on_delete, :any, required: true
  attr :on_toggle, :string, required: true
  attr :on_test, :any, required: true
  attr :on_view_deliveries, :any, required: true

  @spec webhook_card(map()) :: Phoenix.LiveView.Rendered.t()
  def webhook_card(assigns) do
    ~H"""
    <div class={[
      "card-glass p-4 sm:p-6 transition-all duration-300 group",
      if(@webhook.is_active,
        do: "hover:shadow-xl",
        else: "opacity-75 grayscale-[0.3] bg-tymeslot-100/50"
      )
    ]}>
      <div class="flex flex-col gap-4">
        <%!-- Top row: Icon + Info + Toggle --%>
        <div class="flex items-start gap-4 sm:gap-5">
          <%!-- Webhook Icon --%>
          <div class={[
            "p-3 rounded-2xl transition-colors duration-300 shrink-0",
            if(@webhook.is_active,
              do: "bg-tymeslot-50 group-hover:bg-white",
              else: "bg-tymeslot-200"
            )
          ]}>
            <IconComponents.icon
              name={:webhook}
              class={
                if(@webhook.is_active,
                  do: "w-6 h-6 text-turquoise-600",
                  else: "w-6 h-6 text-tymeslot-400"
                )
              }
            />
          </div>

          <%!-- Webhook Details --%>
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-3 mb-2">
              <h3 class={[
                "text-token-xl font-black tracking-tight",
                if(@webhook.is_active, do: "text-tymeslot-900", else: "text-tymeslot-500")
              ]}>
                {@webhook.name}
              </h3>
              <.pill
                :if={!@webhook.is_active}
                tone={:neutral}
                icon="hero-x-circle"
              >
                {dgettext("dashboard_automation", "Disabled")}
              </.pill>
            </div>

            <%= if @webhook.disabled_reason do %>
              <div class="mb-3 text-token-sm text-red-600 font-medium">
                {dgettext("dashboard_automation", "Disabled: %{reason}",
                  reason: @webhook.disabled_reason
                )}
              </div>
            <% end %>

            <div class="text-token-sm text-tymeslot-600 font-mono mb-3 truncate">
              {@webhook.url}
            </div>

            <%!-- Event Tags --%>
            <div class="flex flex-wrap gap-2 mb-4">
              <%= for event <- @webhook.events do %>
                <span class={[
                  "inline-flex items-center gap-1.5 text-xs font-bold px-2.5 py-1 rounded-token-lg border",
                  if(@webhook.is_active,
                    do: "bg-turquoise-50 text-turquoise-700 border-turquoise-200",
                    else: "bg-tymeslot-100 text-tymeslot-500 border-tymeslot-200"
                  )
                ]}>
                  <div class={[
                    "w-1.5 h-1.5 rounded-full",
                    if(@webhook.is_active, do: "bg-turquoise-500", else: "bg-tymeslot-400")
                  ]}>
                  </div>
                  {event}
                </span>
              <% end %>
            </div>

            <%!-- Last Triggered Info --%>
            <%= if @webhook.last_triggered_at do %>
              <div class="flex items-center gap-2 text-token-sm text-tymeslot-500">
                <.icon name="hero-clock" class="w-4 h-4 shrink-0" />
                <span>
                  {dgettext("dashboard_automation", "Last triggered: %{time}",
                    time: Helpers.format_datetime(@webhook.last_triggered_at, @time_format)
                  )}
                  <%= if @webhook.last_status do %>
                    <span class={["ml-1", status_color(@webhook.last_status)]}>
                      ({status_label(@webhook.last_status)})
                    </span>
                  <% end %>
                </span>
              </div>
            <% else %>
              <div class="flex items-center gap-2 text-token-sm text-tymeslot-400 italic">
                <.icon name="hero-clock" class="w-4 h-4 shrink-0" />
                <span>{dgettext("dashboard_automation", "Never triggered")}</span>
              </div>
            <% end %>
          </div>

          <%!-- Status Toggle (top right) --%>
          <div class="shrink-0 ml-2">
            <StatusSwitch.status_switch
              id={"webhook-toggle-#{@webhook.id}"}
              checked={@webhook.is_active}
              on_change={@on_toggle}
              target={@target}
              phx_value_id={"#{@webhook.id}"}
              size={:medium}
              class="ring-4 ring-tymeslot-50 group-hover:ring-turquoise-50 transition-all duration-300"
            />
          </div>
        </div>

        <%!-- Bottom: Actions --%>
        <div class="flex items-center gap-2 shrink-0 border-t border-tymeslot-100 pt-3">
          <%!-- Test Button --%>
          <.loading_button
            variant={:secondary}
            size={:sm}
            icon="hero-bolt"
            loading={@testing}
            loading_text={dgettext("dashboard_automation", "Testing")}
            disabled={!@webhook.is_active}
            phx-click={@on_test}
            title={
              cond do
                !@webhook.is_active -> dgettext("dashboard_automation", "Enable webhook to test")
                @testing -> dgettext("dashboard_automation", "Testing...")
                true -> dgettext("dashboard_automation", "Test Connection")
              end
            }
          >
            {dgettext("dashboard_automation", "Test")}
          </.loading_button>

          <%!-- View Logs Button --%>
          <.action_button
            variant={:secondary}
            size={:sm}
            icon="hero-document-text"
            phx-click={@on_view_deliveries}
            title={dgettext("dashboard_automation", "View Delivery Logs")}
          >
            {dgettext("dashboard_automation", "Logs")}
          </.action_button>

          <div class="ml-auto flex items-center gap-1">
            <%!-- Edit Button --%>
            <.icon_button
              icon="hero-pencil-square"
              label={dgettext("dashboard_automation", "Edit Webhook")}
              phx-click={@on_edit}
            />

            <%!-- Delete Button --%>
            <.icon_button
              icon="hero-trash"
              variant={:danger}
              label={dgettext("dashboard_automation", "Delete Webhook")}
              phx-click={@on_delete}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp status_color(last_status) do
    case DeliveryStatus.state(last_status) do
      :success -> "text-green-600 font-bold"
      :failed -> "text-red-600 font-bold"
      :unknown -> "text-tymeslot-600 font-medium"
    end
  end

  # The raw reason (e.g. "HTTP 500", "connection refused") is machine
  # diagnostic text, not UI copy, so only the state word is translated; the
  # reason is interpolated untranslated, same as the disabled-reason badge.
  defp status_label(last_status) do
    case DeliveryStatus.state(last_status) do
      :success ->
        dgettext("dashboard_automation", "Succeeded")

      :failed ->
        case DeliveryStatus.reason(last_status) do
          nil -> dgettext("dashboard_automation", "Failed")
          reason -> dgettext("dashboard_automation", "Failed: %{reason}", reason: reason)
        end

      :unknown ->
        last_status
    end
  end
end
