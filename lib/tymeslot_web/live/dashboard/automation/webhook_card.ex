defmodule TymeslotWeb.Dashboard.Automation.WebhookCard do
  @moduledoc """
  UI component for displaying a single webhook card.
  """
  use TymeslotWeb, :html

  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Components.UI.StatusSwitch

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
            "p-3 rounded-2xl transition-colors duration-300 flex-shrink-0",
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
                  <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2.5"
                      d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"
                    />
                  </svg>
                  Disabled
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
                <svg class="w-4 h-4 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
                <span>
                  Last triggered: <%= format_datetime(@webhook.last_triggered_at) %>
                  <%= if @webhook.last_status do %>
                    <span class={["ml-1", status_color(@webhook.last_status)]}>
                      (<%= @webhook.last_status %>)
                    </span>
                  <% end %>
                </span>
              </div>
            <% else %>
              <div class="flex items-center gap-2 text-token-sm text-tymeslot-400 italic">
                <svg class="w-4 h-4 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
                <span>Never triggered</span>
              </div>
            <% end %>
          </div>

          <%!-- Status Toggle (top right) --%>
          <div class="flex-shrink-0 ml-2">
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
        <div class="flex items-center gap-2 flex-shrink-0 border-t border-tymeslot-100 pt-3">
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
                !@webhook.is_active -> "Enable webhook to test"
                @testing -> "Testing..."
                true -> "Test Connection"
              end
            }
          >
            <%= if @testing do %>
              <svg class="w-4 h-4 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                />
              </svg>
              <span class="hidden sm:inline">Testing</span>
            <% else %>
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 10V3L4 14h7v7l9-11h-7z"
                />
              </svg>
              Test
            <% end %>
          </button>

          <%!-- View Logs Button --%>
          <button
            phx-click={@on_view_deliveries}
            class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-200 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
            title="View Delivery Logs"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
              />
            </svg>
            Logs
          </button>

          <div class="ml-auto flex items-center gap-1">
            <%!-- Edit Button --%>
            <button
              phx-click={@on_edit}
              class="p-2.5 text-tymeslot-400 hover:text-turquoise-600 hover:bg-turquoise-50 rounded-token-xl transition-all"
              title="Edit Webhook"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
                />
              </svg>
            </button>

            <%!-- Delete Button --%>
            <button
              phx-click={@on_delete}
              class="p-2.5 text-tymeslot-300 hover:text-red-500 hover:bg-red-50 rounded-token-xl transition-all"
              title="Delete Webhook"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %I:%M %p")
  end

  defp status_color("success"), do: "text-green-600 font-bold"
  defp status_color("failed"), do: "text-red-600 font-bold"
  defp status_color(_status), do: "text-tymeslot-600 font-medium"
end
