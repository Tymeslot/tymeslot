defmodule TymeslotWeb.Dashboard.Automation.SlackCard do
  @moduledoc false
  use TymeslotWeb, :html

  alias Tymeslot.Slack.SlackIntegrationSchema
  alias TymeslotWeb.Components.Icons.IconComponents
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
  attr :on_reconnect, :any, default: nil

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
            "p-3 rounded-token-2xl transition-colors duration-300 shrink-0",
            icon_bg(@status)
          ]}>
            <IconComponents.icon name={:slack} class={"w-6 h-6 #{icon_color(@status)}"} />
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
                  <.icon name="hero-clock" class="w-4 h-4 shrink-0" />
                  <span>Last triggered: <%= AutomationHelpers.format_datetime(@integration.last_triggered_at) %></span>
                </div>
              <% else %>
                <div class="flex items-center gap-2 text-token-sm text-tymeslot-400 italic">
                  <.icon name="hero-clock" class="w-4 h-4 shrink-0" />
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
          <div class="shrink-0 ml-2">
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
        <div class="flex items-center gap-2 shrink-0 border-t border-tymeslot-100 pt-3">
          <%!-- Pick a channel (pending_oauth only) --%>
          <%= if @status == :pending_oauth && @on_pick_channel do %>
            <button
              phx-click={@on_pick_channel}
              class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-turquoise-50 border-turquoise-200 text-turquoise-700 hover:bg-turquoise-100 font-bold transition-all text-token-sm"
            >
              Pick a channel
            </button>
          <% end %>

          <%!-- Reconnect (pending_oauth OAuth only — restart OAuth from scratch) --%>
          <%= if @status == :pending_oauth && @integration.app_mode == "oauth" && @on_reconnect do %>
            <button
              phx-click={@on_reconnect}
              class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-amber-200 text-amber-700 hover:bg-amber-50 font-bold transition-all text-token-sm"
            >
              <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect
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
                <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin" />
                <span class="hidden sm:inline">Testing</span>
              <% else %>
                <.icon name="hero-bolt" class="w-4 h-4" />
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
                <.icon name="hero-pencil-square" class="w-5 h-5" />
              </button>
            <% end %>

            <%!-- Disconnect Button (OAuth mode only, once channel is set) --%>
            <%= if @on_disconnect && @integration.app_mode == "oauth" && @integration.channel_id do %>
              <button
                phx-click={@on_disconnect}
                class="p-2.5 text-tymeslot-400 hover:text-amber-600 hover:bg-amber-50 rounded-token-xl transition-all"
                title="Disconnect Slack"
              >
                <.icon name="hero-no-symbol" class="w-5 h-5" />
              </button>
            <% end %>

            <%!-- Delete Button --%>
            <button
              phx-click={@on_delete}
              class="p-2.5 text-tymeslot-300 hover:text-red-500 hover:bg-red-50 rounded-token-xl transition-all"
              title="Delete"
            >
              <.icon name="hero-trash" class="w-5 h-5" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp status_badge(%{status: :pending_oauth} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-amber-100 text-amber-700 text-xs font-black px-2.5 py-1 rounded-token-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-amber-500 animate-pulse" />
      Channel needed
    </span>
    """
  end

  defp status_badge(%{status: :active} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-green-100 text-green-700 text-xs font-black px-2.5 py-1 rounded-token-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-green-500" />
      Active
    </span>
    """
  end

  defp status_badge(%{status: :paused} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-tymeslot-200 text-tymeslot-600 text-xs font-black px-2.5 py-1 rounded-token-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-tymeslot-400" />
      Paused
    </span>
    """
  end

  defp status_badge(%{status: :auto_disabled} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-red-100 text-red-700 text-xs font-black px-2.5 py-1 rounded-token-full uppercase tracking-wide">
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
