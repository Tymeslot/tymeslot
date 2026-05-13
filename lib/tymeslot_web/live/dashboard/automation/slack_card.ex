defmodule TymeslotWeb.Dashboard.Automation.SlackCard do
  @moduledoc false
  use TymeslotWeb, :html

  alias Tymeslot.Slack.SlackIntegrationSchema
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers

  attr :integration, :map, required: true
  attr :testing, :boolean, default: false
  attr :target, :any, required: true
  attr :on_edit, :any, required: true
  attr :on_delete, :any, required: true
  attr :on_toggle, :string, required: true
  attr :on_test, :any, required: true
  attr :on_view_deliveries, :any, required: true
  attr :on_reenable, :any, default: nil
  attr :on_pick_channel, :any, default: nil
  attr :on_disconnect, :any, default: nil

  @spec slack_card(map()) :: Phoenix.LiveView.Rendered.t()
  def slack_card(assigns) do
    assigns = assign(assigns, :status, SlackIntegrationSchema.status(assigns.integration))

    ~H"""
    <div class={[
      "card-glass p-4 sm:p-6 transition-all duration-300 group",
      card_style(@status)
    ]}>
      <div class="flex flex-col gap-4">
        <%!-- Top row: Icon + Info + Toggle/Badge --%>
        <div class="flex items-start gap-4 sm:gap-5">
          <%!-- Slack Icon --%>
          <div class={[
            "p-3 rounded-2xl transition-colors duration-300 flex-shrink-0",
            icon_bg(@status)
          ]}>
            <svg class={["w-6 h-6", icon_color(@status)]} viewBox="0 0 24 24" fill="currentColor">
              <path d="M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z" />
            </svg>
          </div>

          <%!-- Integration Details --%>
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-3 mb-2">
              <h3 class={[
                "text-token-xl font-black tracking-tight",
                if(@status == :active, do: "text-tymeslot-900", else: "text-tymeslot-500")
              ]}>
                <%= @integration.name %>
              </h3>
              <.status_badge status={@status} reason={@integration.disabled_reason} />
            </div>

            <div class="text-token-sm text-tymeslot-600 font-medium mb-3 truncate">
              <%= location_label(@integration) %>
            </div>

            <%!-- Event Tags --%>
            <div class="flex flex-wrap gap-2 mb-4">
              <%= for event <- @integration.events do %>
                <span class={[
                  "inline-flex items-center gap-1.5 text-xs font-bold px-2.5 py-1 rounded-token-lg border",
                  event_tag_style(@status)
                ]}>
                  <div class={["w-1.5 h-1.5 rounded-full", event_dot_style(@status)]} />
                  <%= event %>
                </span>
              <% end %>
            </div>

            <%!-- Status-specific content --%>
            <%= if @status == :pending_oauth do %>
              <div class="text-token-sm text-amber-600 font-medium">
                Pick a channel to finish setup.
              </div>
            <% else %>
              <%= if @integration.last_triggered_at do %>
                <div class="flex items-center gap-2 text-token-sm text-tymeslot-500">
                  <svg class="w-4 h-4 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                  <span>Last triggered: <%= AutomationHelpers.format_datetime(@integration.last_triggered_at) %></span>
                </div>
              <% else %>
                <div class="flex items-center gap-2 text-token-sm text-tymeslot-400 italic">
                  <svg class="w-4 h-4 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                  <span>Never triggered</span>
                </div>
              <% end %>

              <%= if @status == :auto_disabled do %>
                <div class="mt-2 text-token-sm text-red-600 font-medium">
                  Disabled: <%= disabled_reason_label(@integration.disabled_reason) %>
                </div>
              <% end %>
            <% end %>
          </div>

          <%!-- Status Toggle (active/paused only) --%>
          <div class="flex-shrink-0 ml-2">
            <%= if @status in [:active, :paused] do %>
              <StatusSwitch.status_switch
                id={"slack-toggle-#{@integration.id}"}
                checked={@integration.is_active}
                on_change={@on_toggle}
                target={@target}
                phx_value_id={"#{@integration.id}"}
                size={:medium}
                class="ring-4 ring-tymeslot-50 group-hover:ring-turquoise-50 transition-all duration-300"
              />
            <% end %>
          </div>
        </div>

        <%!-- Bottom: Actions --%>
        <div class="flex items-center gap-2 flex-shrink-0 border-t border-tymeslot-100 pt-3">
          <%!-- Pick a channel (pending_oauth only) --%>
          <%= if @status == :pending_oauth && @on_pick_channel do %>
            <button
              phx-click={@on_pick_channel}
              class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-turquoise-50 border-turquoise-200 text-turquoise-700 hover:bg-turquoise-100 font-bold transition-all text-token-sm"
            >
              Pick a channel
            </button>
          <% end %>

          <%!-- Test Button --%>
          <%= if @status in [:active, :paused] do %>
            <button
              phx-click={@on_test}
              disabled={@testing || @status != :active}
              class={[
                "inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 font-bold transition-all text-token-sm",
                if(@status == :active && !@testing,
                  do: "bg-white border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-200 hover:bg-turquoise-50",
                  else: "bg-tymeslot-50 border-tymeslot-100 text-tymeslot-400 cursor-not-allowed opacity-50"
                )
              ]}
            >
              <%= if @testing do %>
                <svg class="w-4 h-4 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                </svg>
                <span class="hidden sm:inline">Testing</span>
              <% else %>
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
                </svg>
                Test
              <% end %>
            </button>
          <% end %>

          <%!-- Re-enable Button (auto_disabled only) --%>
          <%= if @status == :auto_disabled && @on_reenable do %>
            <button
              phx-click={@on_reenable}
              class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-turquoise-200 text-turquoise-700 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
            >
              Re-enable
            </button>
          <% end %>

          <%!-- Logs Button --%>
          <%= if @status != :pending_oauth do %>
            <button
              phx-click={@on_view_deliveries}
              class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-200 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
              </svg>
              Logs
            </button>
          <% end %>

          <div class="ml-auto flex items-center gap-1">
            <%!-- Edit Button --%>
            <%= if @status != :pending_oauth do %>
              <button
                phx-click={@on_edit}
                class="p-2.5 text-tymeslot-400 hover:text-turquoise-600 hover:bg-turquoise-50 rounded-token-xl transition-all"
                title="Edit"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
                </svg>
              </button>
            <% end %>

            <%!-- Disconnect Button (OAuth mode only, once channel is set) --%>
            <%= if @on_disconnect && @integration.app_mode == "oauth" && @integration.channel_id do %>
              <button
                phx-click={@on_disconnect}
                class="p-2.5 text-tymeslot-400 hover:text-amber-600 hover:bg-amber-50 rounded-token-xl transition-all"
                title="Disconnect Slack"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1" />
                </svg>
              </button>
            <% end %>

            <%!-- Delete Button --%>
            <button
              phx-click={@on_delete}
              class="p-2.5 text-tymeslot-300 hover:text-red-500 hover:bg-red-50 rounded-token-xl transition-all"
              title="Delete"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
              </svg>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp status_badge(%{status: :pending_oauth} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-amber-100 text-amber-700 text-xs font-black px-2.5 py-1 rounded-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-amber-500 animate-pulse" />
      Channel needed
    </span>
    """
  end

  defp status_badge(%{status: :active} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-green-100 text-green-700 text-xs font-black px-2.5 py-1 rounded-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-green-500" />
      Active
    </span>
    """
  end

  defp status_badge(%{status: :paused} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-tymeslot-200 text-tymeslot-600 text-xs font-black px-2.5 py-1 rounded-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-tymeslot-400" />
      Paused
    </span>
    """
  end

  defp status_badge(%{status: :auto_disabled} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-red-100 text-red-700 text-xs font-black px-2.5 py-1 rounded-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-red-500" />
      Disabled
    </span>
    """
  end

  defp card_style(:active), do: "hover:shadow-xl"
  defp card_style(:paused), do: "opacity-75 grayscale-[0.3] bg-tymeslot-100/50"
  defp card_style(:auto_disabled), do: "opacity-75 border-red-200 bg-red-50/30"
  defp card_style(:pending_oauth), do: "border-amber-200 bg-amber-50/30"

  defp icon_bg(:active), do: "bg-tymeslot-50 group-hover:bg-white"
  defp icon_bg(:pending_oauth), do: "bg-amber-50"
  defp icon_bg(_status), do: "bg-tymeslot-200"

  defp icon_color(:active), do: "text-turquoise-600"
  defp icon_color(:pending_oauth), do: "text-amber-600"
  defp icon_color(:auto_disabled), do: "text-red-400"
  defp icon_color(_status), do: "text-tymeslot-400"

  defp event_tag_style(:active), do: "bg-turquoise-50 text-turquoise-700 border-turquoise-200"
  defp event_tag_style(_status), do: "bg-tymeslot-100 text-tymeslot-500 border-tymeslot-200"

  defp event_dot_style(:active), do: "bg-turquoise-500"
  defp event_dot_style(_status), do: "bg-tymeslot-400"

  # Renders the human-readable destination for the integration: workspace and
  # channel for OAuth installs, or "Custom webhook" with channel hint for
  # pasted Incoming Webhook URLs.
  defp location_label(%{app_mode: "oauth"} = integration) do
    workspace = integration.team_name || "Slack workspace"

    case integration.channel_name do
      nil -> workspace
      channel -> "#{workspace} · ##{String.trim_leading(channel, "#")}"
    end
  end

  defp location_label(%{app_mode: "webhook_url"} = integration) do
    case integration.webhook_channel_hint do
      nil -> "Custom webhook"
      "" -> "Custom webhook"
      hint -> "Custom webhook · ##{String.trim_leading(hint, "#")}"
    end
  end

  defp location_label(_integration), do: "Slack"

  defp disabled_reason_label(nil), do: "auto-disabled"
  defp disabled_reason_label(""), do: "auto-disabled"

  defp disabled_reason_label("webhook_url_revoked"),
    do: "webhook URL was revoked in Slack"

  defp disabled_reason_label(reason) when is_binary(reason), do: reason
end
