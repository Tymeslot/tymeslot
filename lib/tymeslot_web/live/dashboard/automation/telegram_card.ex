defmodule TymeslotWeb.Dashboard.Automation.TelegramCard do
  @moduledoc false
  use TymeslotWeb, :html

  alias TymeslotWeb.Components.UI.StatusSwitch

  attr :integration, :map, required: true
  attr :testing, :boolean, default: false
  attr :target, :any, required: true
  attr :on_edit, :any, required: true
  attr :on_delete, :any, required: true
  attr :on_toggle, :string, required: true
  attr :on_test, :any, required: true
  attr :on_view_deliveries, :any, required: true
  attr :on_reenable, :any, default: nil
  attr :on_disconnect, :any, default: nil
  attr :on_reconnect, :any, default: nil

  @spec telegram_card(map()) :: Phoenix.LiveView.Rendered.t()
  def telegram_card(assigns) do
    ~H"""
    <div class={[
      "card-glass p-4 sm:p-6 transition-all duration-300 group",
      card_style(@integration.status)
    ]}>
      <div class="flex flex-col gap-4">
        <!-- Top row: Icon + Info + Toggle/Badge -->
        <div class="flex items-start gap-4 sm:gap-5">
          <!-- Telegram Icon -->
          <div class={[
            "p-3 rounded-2xl transition-colors duration-300 flex-shrink-0",
            icon_bg(@integration.status)
          ]}>
            <svg class={["w-6 h-6", icon_color(@integration.status)]} viewBox="0 0 24 24" fill="currentColor">
              <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
            </svg>
          </div>

          <!-- Integration Details -->
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-3 mb-2">
              <h3 class={[
                "text-token-xl font-black tracking-tight",
                if(@integration.status == :active, do: "text-slate-900", else: "text-slate-500")
              ]}>
                <%= @integration.name %>
              </h3>
              <.status_badge status={@integration.status} reason={@integration.disabled_reason} />
            </div>

            <%= if @integration.chat_id do %>
              <div class="text-token-sm text-slate-600 font-mono mb-3 truncate">
                Chat: <%= truncate_chat_id(@integration.chat_id) %>
              </div>
            <% end %>

            <!-- Event Tags -->
            <div class="flex flex-wrap gap-2 mb-4">
              <%= for event <- @integration.events do %>
                <span class={[
                  "inline-flex items-center gap-1.5 text-xs font-bold px-2.5 py-1 rounded-token-lg border",
                  event_tag_style(@integration.status)
                ]}>
                  <div class={["w-1.5 h-1.5 rounded-full", event_dot_style(@integration.status)]} />
                  <%= event %>
                </span>
              <% end %>
            </div>

            <!-- Status-specific content -->
            <%= if @integration.status == :pending_link do %>
              <div class="text-token-sm text-amber-600 font-medium">
                Connect Telegram to start receiving notifications.
              </div>
            <% else %>
              <!-- Last Triggered Info -->
              <%= if @integration.last_triggered_at do %>
                <div class="flex items-center gap-2 text-token-sm text-slate-500">
                  <svg class="w-4 h-4 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                  <span>Last triggered: <%= format_datetime(@integration.last_triggered_at) %></span>
                </div>
              <% else %>
                <div class="flex items-center gap-2 text-token-sm text-slate-400 italic">
                  <svg class="w-4 h-4 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                  <span>Never triggered</span>
                </div>
              <% end %>

              <%= if @integration.status == :auto_disabled do %>
                <div class="mt-2 text-token-sm text-red-600 font-medium">
                  Disabled: <%= @integration.disabled_reason %>
                </div>
              <% end %>
            <% end %>
          </div>

          <!-- Status Toggle (active/paused only) -->
          <div class="flex-shrink-0 ml-2">
            <%= if @integration.status in [:active, :paused] do %>
              <StatusSwitch.status_switch
                id={"telegram-toggle-#{@integration.id}"}
                checked={@integration.is_active}
                on_change={@on_toggle}
                target={@target}
                phx_value_id={"#{@integration.id}"}
                size={:medium}
                class="ring-4 ring-slate-50 group-hover:ring-turquoise-50 transition-all duration-300"
              />
            <% end %>
          </div>
        </div>

        <!-- Bottom: Actions -->
        <div class="flex items-center gap-2 flex-shrink-0 border-t border-slate-100 pt-3">
          <!-- Test Button -->
          <%= if @integration.status in [:active, :paused] do %>
            <button
              phx-click={@on_test}
              disabled={@testing || @integration.status != :active}
              class={[
                "inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 font-bold transition-all text-token-sm",
                if(@integration.status == :active && !@testing,
                  do: "bg-white border-slate-100 text-slate-700 hover:border-turquoise-200 hover:bg-turquoise-50",
                  else: "bg-slate-50 border-slate-100 text-slate-400 cursor-not-allowed opacity-50"
                )
              ]}
            >
              <%= if @testing do %>
                <svg class="w-4 h-4 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                </svg>
                <span class="hidden xs:inline">Testing</span>
              <% else %>
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
                </svg>
                Test
              <% end %>
            </button>
          <% end %>

          <!-- Connect Button (pending_link + shared bot only) -->
          <%= if @integration.status == :pending_link && @integration.bot_mode == "shared" && @on_reconnect do %>
            <button
              phx-click={@on_reconnect}
              class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-turquoise-200 text-turquoise-700 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
            >
              Connect
            </button>
          <% end %>

          <!-- Re-enable Button (auto_disabled only) -->
          <%= if @integration.status == :auto_disabled && @on_reenable do %>
            <button
              phx-click={@on_reenable}
              class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-turquoise-200 text-turquoise-700 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
            >
              Re-enable
            </button>
          <% end %>

          <!-- Logs Button -->
          <button
            phx-click={@on_view_deliveries}
            class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-slate-100 text-slate-700 hover:border-turquoise-200 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
            </svg>
            Logs
          </button>

          <div class="ml-auto flex items-center gap-1">
            <!-- Edit Button -->
            <%= if @integration.status != :pending_link do %>
              <button
                phx-click={@on_edit}
                class="p-2.5 text-slate-400 hover:text-turquoise-600 hover:bg-turquoise-50 rounded-token-xl transition-all"
                title="Edit"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
                </svg>
              </button>
            <% end %>

            <!-- Disconnect Button (shared bot mode only) -->
            <%= if @on_disconnect && @integration.bot_mode == "shared" && @integration.chat_id do %>
              <button
                phx-click={@on_disconnect}
                class="p-2.5 text-slate-400 hover:text-amber-600 hover:bg-amber-50 rounded-token-xl transition-all"
                title="Disconnect Telegram"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1" />
                </svg>
              </button>
            <% end %>

            <!-- Delete Button -->
            <button
              phx-click={@on_delete}
              class="p-2.5 text-slate-300 hover:text-red-500 hover:bg-red-50 rounded-token-xl transition-all"
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

  defp status_badge(%{status: :pending_link} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-amber-100 text-amber-700 text-xs font-black px-2.5 py-1 rounded-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-amber-500 animate-pulse" />
      Awaiting connection
    </span>
    """
  end

  defp status_badge(%{status: :active} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-green-100 text-green-700 text-xs font-black px-2.5 py-1 rounded-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-green-500" />
      Connected
    </span>
    """
  end

  defp status_badge(%{status: :paused} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 bg-slate-200 text-slate-600 text-xs font-black px-2.5 py-1 rounded-full uppercase tracking-wide">
      <div class="w-1.5 h-1.5 rounded-full bg-slate-400" />
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
  defp card_style(:paused), do: "opacity-75 grayscale-[0.3] bg-slate-100/50"
  defp card_style(:auto_disabled), do: "opacity-75 border-red-200 bg-red-50/30"
  defp card_style(:pending_link), do: "border-amber-200 bg-amber-50/30"

  defp icon_bg(:active), do: "bg-slate-50 group-hover:bg-white"
  defp icon_bg(:pending_link), do: "bg-amber-50"
  defp icon_bg(_status), do: "bg-slate-200"

  defp icon_color(:active), do: "text-turquoise-600"
  defp icon_color(:pending_link), do: "text-amber-600"
  defp icon_color(:auto_disabled), do: "text-red-400"
  defp icon_color(_status), do: "text-slate-400"

  defp event_tag_style(:active), do: "bg-turquoise-50 text-turquoise-700 border-turquoise-200"
  defp event_tag_style(_status), do: "bg-slate-100 text-slate-500 border-slate-200"

  defp event_dot_style(:active), do: "bg-turquoise-500"
  defp event_dot_style(_status), do: "bg-slate-400"

  defp truncate_chat_id(chat_id) when is_binary(chat_id) do
    if String.length(chat_id) > 12 do
      String.slice(chat_id, 0, 12) <> "..."
    else
      chat_id
    end
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %I:%M %p")
  end
end
