defmodule TymeslotWeb.Dashboard.Automation.WebhookCard do
  @moduledoc """
  UI component for displaying a single webhook card.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Dashboard.Automation.Helpers

  attr :webhook, :map, required: true
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
                <%= @webhook.name %>
              </h3>
              <%= if !@webhook.is_active do %>
                <span class="inline-flex items-center gap-1 bg-tymeslot-200 text-tymeslot-600 text-xs font-black px-2.5 py-1 rounded-full uppercase tracking-wide">
                  <.icon name="hero-x-circle" class="w-3 h-3" />
                  {dgettext("dashboard_automation", "Disabled")}
                </span>
              <% end %>
            </div>

            <div class="text-token-sm text-tymeslot-600 font-mono mb-3 truncate">
              <%= @webhook.url %>
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
                  <%= event %>
                </span>
              <% end %>
            </div>

            <%!-- Last Triggered Info --%>
            <%= if @webhook.last_triggered_at do %>
              <div class="flex items-center gap-2 text-token-sm text-tymeslot-500">
                <.icon name="hero-clock" class="w-4 h-4 shrink-0" />
                <span>
                  {dgettext("dashboard_automation", "Last triggered: %{time}",
                    time: Helpers.format_datetime(@webhook.last_triggered_at)
                  )}
                  <%= if @webhook.last_status do %>
                    <span class={["ml-1", status_color(@webhook.last_status)]}>
                      (<%= @webhook.last_status %>)
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
          <button
            phx-click={@on_test}
            disabled={@testing || !@webhook.is_active}
            class={[
              "inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 font-bold transition-all text-token-sm",
              if(@webhook.is_active && !@testing,
                do: "bg-white border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-200 hover:bg-turquoise-50",
                else: "bg-tymeslot-50 border-tymeslot-100 text-tymeslot-400 cursor-not-allowed opacity-50"
              )
            ]}
            title={
              cond do
                !@webhook.is_active -> dgettext("dashboard_automation", "Enable webhook to test")
                @testing -> dgettext("dashboard_automation", "Testing...")
                true -> dgettext("dashboard_automation", "Test Connection")
              end
            }
          >
            <%= if @testing do %>
              <.spinner class="w-4 h-4" />
              <span class="hidden sm:inline">{dgettext("dashboard_automation", "Testing")}</span>
            <% else %>
              <.icon name="hero-bolt" class="w-4 h-4" />
              {dgettext("dashboard_automation", "Test")}
            <% end %>
          </button>

          <%!-- View Logs Button --%>
          <button
            phx-click={@on_view_deliveries}
            class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-200 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
            title={dgettext("dashboard_automation", "View Delivery Logs")}
          >
            <.icon name="hero-document-text" class="w-4 h-4" />
            {dgettext("dashboard_automation", "Logs")}
          </button>

          <div class="ml-auto flex items-center gap-1">
            <%!-- Edit Button --%>
            <button
              phx-click={@on_edit}
              class="p-2.5 text-tymeslot-400 hover:text-turquoise-600 hover:bg-turquoise-50 rounded-token-xl transition-all"
              title={dgettext("dashboard_automation", "Edit Webhook")}
            >
              <.icon name="hero-pencil-square" class="w-5 h-5" />
            </button>

            <%!-- Delete Button --%>
            <button
              phx-click={@on_delete}
              class="p-2.5 text-tymeslot-300 hover:text-red-500 hover:bg-red-50 rounded-token-xl transition-all"
              title={dgettext("dashboard_automation", "Delete Webhook")}
            >
              <.icon name="hero-trash" class="w-5 h-5" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp status_color("success"), do: "text-green-600 font-bold"
  defp status_color("failed"), do: "text-red-600 font-bold"
  defp status_color(_status), do: "text-tymeslot-600 font-medium"
end
