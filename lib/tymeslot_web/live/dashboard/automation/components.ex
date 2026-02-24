defmodule TymeslotWeb.Dashboard.Automation.Components do
  @moduledoc """
  UI components for automation settings.
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
        else: "opacity-75 grayscale-[0.3] bg-slate-100/50"
      )
    ]}>
      <div class="flex flex-col gap-4">
        <!-- Top row: Icon + Info + Toggle -->
        <div class="flex items-start gap-4 sm:gap-5">
          <!-- Webhook Icon -->
          <div class={[
            "p-3 rounded-2xl transition-colors duration-300 flex-shrink-0",
            if(@webhook.is_active,
              do: "bg-slate-50 group-hover:bg-white",
              else: "bg-slate-200"
            )
          ]}>
            <IconComponents.icon
              name={:webhook}
              class={
                if(@webhook.is_active,
                  do: "w-6 h-6 text-turquoise-600",
                  else: "w-6 h-6 text-slate-400"
                )
              }
            />
          </div>

          <!-- Webhook Details -->
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-3 mb-2">
              <h3 class={[
                "text-token-xl font-black tracking-tight",
                if(@webhook.is_active, do: "text-slate-900", else: "text-slate-500")
              ]}>
                <%= @webhook.name %>
              </h3>
              <%= if !@webhook.is_active do %>
                <span class="inline-flex items-center gap-1 bg-slate-200 text-slate-600 text-xs font-black px-2.5 py-1 rounded-full uppercase tracking-wide">
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

            <div class="text-token-sm text-slate-600 font-mono mb-3 truncate">
              <%= @webhook.url %>
            </div>

            <!-- Event Tags -->
            <div class="flex flex-wrap gap-2 mb-4">
              <%= for event <- @webhook.events do %>
                <span class={[
                  "inline-flex items-center gap-1.5 text-xs font-bold px-2.5 py-1 rounded-token-lg border",
                  if(@webhook.is_active,
                    do: "bg-turquoise-50 text-turquoise-700 border-turquoise-200",
                    else: "bg-slate-100 text-slate-500 border-slate-200"
                  )
                ]}>
                  <div class={[
                    "w-1.5 h-1.5 rounded-full",
                    if(@webhook.is_active, do: "bg-turquoise-500", else: "bg-slate-400")
                  ]}>
                  </div>
                  <%= event %>
                </span>
              <% end %>
            </div>

            <!-- Last Triggered Info -->
            <%= if @webhook.last_triggered_at do %>
              <div class="flex items-center gap-2 text-token-sm text-slate-500">
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
              <div class="flex items-center gap-2 text-token-sm text-slate-400 italic">
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

          <!-- Status Toggle (top right) -->
          <div class="flex-shrink-0 ml-2">
            <StatusSwitch.status_switch
              id={"webhook-toggle-#{@webhook.id}"}
              checked={@webhook.is_active}
              on_change={@on_toggle}
              target={@target}
              phx_value_id={"#{@webhook.id}"}
              size={:medium}
              class="ring-4 ring-slate-50 group-hover:ring-turquoise-50 transition-all duration-300"
            />
          </div>
        </div>

        <!-- Bottom: Actions -->
        <div class="flex items-center gap-2 flex-shrink-0 border-t border-slate-100 pt-3">
          <!-- Test Button -->
          <button
            phx-click={@on_test}
            disabled={@testing || !@webhook.is_active}
            class={[
              "inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 font-bold transition-all text-token-sm",
              if(@webhook.is_active && !@testing,
                do: "bg-white border-slate-100 text-slate-700 hover:border-turquoise-200 hover:bg-turquoise-50",
                else: "bg-slate-50 border-slate-100 text-slate-400 cursor-not-allowed opacity-50"
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
              <span class="hidden xs:inline">Testing</span>
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

          <!-- View Logs Button -->
          <button
            phx-click={@on_view_deliveries}
            class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-slate-100 text-slate-700 hover:border-turquoise-200 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
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
            <!-- Edit Button -->
            <button
              phx-click={@on_edit}
              class="p-2.5 text-slate-400 hover:text-turquoise-600 hover:bg-turquoise-50 rounded-token-xl transition-all"
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

            <!-- Delete Button -->
            <button
              phx-click={@on_delete}
              class="p-2.5 text-slate-300 hover:text-red-500 hover:bg-red-50 rounded-token-xl transition-all"
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

  attr :on_create, :any, required: true

  @spec webhook_empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def webhook_empty_state(assigns) do
    ~H"""
    <div class="card-glass text-center py-16">
      <div class="w-20 h-20 bg-turquoise-50 rounded-token-3xl mx-auto mb-6 flex items-center justify-center border-2 border-turquoise-100">
        <IconComponents.icon name={:webhook} class="w-10 h-10 text-turquoise-600" />
      </div>

      <h3 class="text-token-2xl font-black text-tymeslot-900 mb-3">No Webhooks Yet</h3>
      <p class="text-tymeslot-600 font-medium mb-8 max-w-md mx-auto">
        Set up webhooks to automatically trigger actions in n8n, Zapier, or your custom tools when bookings are created, cancelled, or rescheduled.
      </p>

      <button phx-click={@on_create} class="btn-primary">
        Create Your First Webhook
      </button>
    </div>
    """
  end

  @spec webhook_documentation(map()) :: Phoenix.LiveView.Rendered.t()
  def webhook_documentation(assigns) do
    ~H"""
    <div class="card-glass space-y-8">
      <div class="flex items-start gap-4">
        <div class="p-3 bg-gradient-to-br from-turquoise-500 to-cyan-500 rounded-2xl shadow-lg shadow-turquoise-500/20">
          <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253"
            />
          </svg>
        </div>
        <div class="flex-1">
          <h3 class="text-token-2xl font-black text-slate-900 tracking-tight">
            Webhook Integration Guide
          </h3>
          <p class="text-token-sm text-slate-600 font-medium mt-1">
            Connect Tymeslot to n8n, Zapier, Make, or your custom automation workflows
          </p>
        </div>
      </div>

      <div class="space-y-6">
        <!-- What are webhooks -->
        <div class="p-5 bg-gradient-to-br from-turquoise-50 to-cyan-50 rounded-token-2xl border-2 border-turquoise-100">
          <div class="flex items-start gap-3 mb-3">
            <div class="w-2 h-2 rounded-full bg-turquoise-500 animate-pulse mt-1.5"></div>
            <h4 class="text-token-lg font-black text-slate-900">What are webhooks?</h4>
          </div>
          <p class="text-slate-700 font-medium ml-5">
            Webhooks send real-time HTTP POST notifications to your automation tools whenever booking events occur.
            Perfect for triggering automated workflows, sending custom emails, syncing data, or building integrations.
          </p>
        </div>

        <!-- Quick Setup -->
        <div>
          <div class="flex items-start gap-3 mb-4">
            <div class="w-2 h-2 rounded-full bg-turquoise-500 animate-pulse mt-1.5"></div>
            <h4 class="text-token-lg font-black text-slate-900">Quick Setup with n8n</h4>
          </div>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3 ml-5">
            <%= for {step, step_index} <- Enum.with_index([
              {"Create a workflow", "Start a new workflow in your n8n instance"},
              {"Add webhook trigger", "Insert a Webhook node and copy its URL"},
              {"Configure in Tymeslot", "Create a webhook above and paste the URL"},
              {"Select events", "Choose which booking events to monitor"},
              {"Test connection", "Verify the webhook is working correctly"},
              {"Build automation", "Add actions to process the webhook data"}
            ], 1) do %>
              <div class="flex items-start gap-3 p-3 bg-white rounded-token-xl border-2 border-slate-100 hover:border-turquoise-200 transition-all">
                <div class="flex-shrink-0 w-6 h-6 rounded-full bg-gradient-to-br from-turquoise-500 to-cyan-500 text-white flex items-center justify-center text-xs font-black">
                  <%= step_index %>
                </div>
                <div class="flex-1 min-w-0">
                  <div class="font-black text-slate-900 text-token-sm"><%= elem(step, 0) %></div>
                  <div class="text-slate-600 text-token-xs font-medium"><%= elem(step, 1) %></div>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Available Events -->
        <div>
          <div class="flex items-start gap-3 mb-4">
            <div class="w-2 h-2 rounded-full bg-turquoise-500 animate-pulse mt-1.5"></div>
            <h4 class="text-token-lg font-black text-slate-900">Available Events</h4>
          </div>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-3 ml-5">
            <%= for {event, icon_path} <- [
              {"meeting.created", "M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"},
              {"meeting.cancelled", "M6 18L18 6M6 6l12 12"},
              {"meeting.rescheduled", "M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"}
            ] do %>
              <div class="p-4 bg-white rounded-token-xl border-2 border-slate-100 hover:border-turquoise-200 hover:shadow-md transition-all">
                <div class="flex items-center gap-2 mb-2">
                  <div class="p-1.5 bg-turquoise-50 rounded-lg">
                    <svg class="w-4 h-4 text-turquoise-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d={icon_path} />
                    </svg>
                  </div>
                  <code class="text-token-sm font-black text-slate-900"><%= event %></code>
                </div>
                <p class="text-token-xs text-slate-600 font-medium">
                  <%= case event do %>
                    <% "meeting.created" -> %>
                      Triggers when a new booking is successfully created
                    <% "meeting.cancelled" -> %>
                      Triggers when an existing booking is cancelled
                    <% "meeting.rescheduled" -> %>
                      Triggers when a booking time is changed
                  <% end %>
                </p>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Security -->
        <div>
          <div class="flex items-start gap-3 mb-4">
            <div class="w-2 h-2 rounded-full bg-turquoise-500 animate-pulse mt-1.5"></div>
            <h4 class="text-token-lg font-black text-slate-900">Security & Authentication</h4>
          </div>
          <div class="ml-5 space-y-3">
            <div class="p-4 bg-slate-50 rounded-token-xl border-2 border-slate-100">
              <div class="flex items-start gap-3">
                <div class="p-2 bg-white rounded-lg flex-shrink-0">
                  <svg class="w-5 h-5 text-turquoise-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                    />
                  </svg>
                </div>
                <div class="flex-1">
                  <p class="text-slate-700 font-medium mb-2">
                    All webhook requests include a unique security token in the HTTP headers for verification:
                  </p>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
                    <div class="flex items-center gap-2 p-2 bg-white rounded-lg">
                      <code class="text-token-xs font-black text-turquoise-700 bg-turquoise-50 px-2 py-1 rounded">
                        X-Tymeslot-Token
                      </code>
                      <span class="text-token-xs text-slate-600 font-medium">Security token</span>
                    </div>
                    <div class="flex items-center gap-2 p-2 bg-white rounded-lg">
                      <code class="text-token-xs font-black text-turquoise-700 bg-turquoise-50 px-2 py-1 rounded">
                        X-Tymeslot-Timestamp
                      </code>
                      <span class="text-token-xs text-slate-600 font-medium">Request timestamp</span>
                    </div>
                  </div>
                  <p class="text-slate-600 text-token-xs font-medium mt-2">
                    Verify the token in your automation tool to ensure requests are from Tymeslot.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %I:%M %p")
  end

  defp status_color("success"), do: "text-green-600 font-bold"
  defp status_color("failed"), do: "text-red-600 font-bold"
  defp status_color(_status), do: "text-tymeslot-600 font-medium"
end
