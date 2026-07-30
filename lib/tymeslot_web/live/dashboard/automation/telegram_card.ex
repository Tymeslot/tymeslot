defmodule TymeslotWeb.Dashboard.Automation.TelegramCard do
  @moduledoc false
  use TymeslotWeb, :html

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
        <%!-- Top row: Icon + Info + Toggle/Badge --%>
        <div class="flex items-start gap-4 sm:gap-5">
          <%!-- Telegram Icon --%>
          <div class={[
            "p-3 rounded-2xl transition-colors duration-300 shrink-0",
            icon_bg(@integration.status)
          ]}>
            <IconComponents.icon
              name={:telegram}
              class={"w-6 h-6 #{icon_color(@integration.status)}"}
            />
          </div>

          <%!-- Integration Details --%>
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-3 mb-2">
              <h3 class={[
                "text-token-xl font-black tracking-tight",
                if(@integration.status == :active, do: "text-tymeslot-900", else: "text-tymeslot-500")
              ]}>
                <%= @integration.name %>
              </h3>
              <.status_badge status={@integration.status} reason={@integration.disabled_reason} />
            </div>

            <%= if @integration.chat_id do %>
              <div class="text-token-sm text-tymeslot-600 font-mono mb-3 truncate">
                Chat: <%= truncate_chat_id(@integration.chat_id) %>
              </div>
            <% end %>

            <%!-- Event Tags --%>
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

            <%!-- Status-specific content --%>
            <%= if @integration.status == :pending_link do %>
              <div class="text-token-sm text-amber-600 font-medium">
                Connect Telegram to start receiving notifications.
              </div>
            <% else %>
              <%!-- Last Triggered Info --%>
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

              <%= if @integration.status == :auto_disabled do %>
                <div class="mt-2 text-token-sm text-red-600 font-medium">
                  Disabled: <%= @integration.disabled_reason %>
                </div>
              <% end %>
            <% end %>
          </div>

          <%!-- Status Toggle (active/paused only) --%>
          <div class="shrink-0 ml-2">
            <%= if @integration.status in [:active, :paused] do %>
              <StatusSwitch.status_switch
                id={"telegram-toggle-#{@integration.id}"}
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
          <%!-- Test Button --%>
          <%= if @integration.status in [:active, :paused] do %>
            <button
              phx-click={@on_test}
              disabled={@testing || @integration.status != :active}
              class={[
                "inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 font-bold transition-all text-token-sm",
                if(@integration.status == :active && !@testing,
                  do: "bg-white border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-200 hover:bg-turquoise-50",
                  else: "bg-tymeslot-50 border-tymeslot-100 text-tymeslot-400 cursor-not-allowed opacity-50"
                )
              ]}
            >
              <%= if @testing do %>
                <.spinner class="w-4 h-4" />
                <span class="hidden sm:inline">Testing</span>
              <% else %>
                <.icon name="hero-bolt" class="w-4 h-4" />
                Test
              <% end %>
            </button>
          <% end %>

          <%!-- Connect Button (pending_link + shared bot only) --%>
          <%= if @integration.status == :pending_link && @integration.bot_mode == "shared" && @on_reconnect do %>
            <button
              phx-click={@on_reconnect}
              class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-turquoise-200 text-turquoise-700 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
            >
              Connect
            </button>
          <% end %>

          <%!-- Re-enable Button (auto_disabled only) --%>
          <%= if @integration.status == :auto_disabled && @on_reenable do %>
            <button
              phx-click={@on_reenable}
              class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-turquoise-200 text-turquoise-700 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
            >
              Re-enable
            </button>
          <% end %>

          <%!-- Logs Button --%>
          <button
            phx-click={@on_view_deliveries}
            class="inline-flex items-center gap-1.5 px-3 py-2 rounded-token-xl border-2 bg-white border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-200 hover:bg-turquoise-50 font-bold transition-all text-token-sm"
          >
            <.icon name="hero-document-text" class="w-4 h-4" />
            Logs
          </button>

          <div class="ml-auto flex items-center gap-1">
            <%!-- Edit Button --%>
            <%= if @integration.status != :pending_link do %>
              <button
                phx-click={@on_edit}
                class="p-2.5 text-tymeslot-400 hover:text-turquoise-600 hover:bg-turquoise-50 rounded-token-xl transition-all"
                title="Edit"
              >
                <.icon name="hero-pencil-square" class="w-5 h-5" />
              </button>
            <% end %>

            <%!-- Disconnect Button (shared bot mode only) --%>
            <%= if @on_disconnect && @integration.bot_mode == "shared" && @integration.chat_id do %>
              <button
                phx-click={@on_disconnect}
                class="p-2.5 text-tymeslot-400 hover:text-amber-600 hover:bg-amber-50 rounded-token-xl transition-all"
                title="Disconnect Telegram"
              >
                <.icon name="hero-link" class="w-5 h-5" />
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
  defp card_style(:pending_link), do: "border-amber-200 bg-amber-50/30"

  defp icon_bg(:active), do: "bg-tymeslot-50 group-hover:bg-white"
  defp icon_bg(:pending_link), do: "bg-amber-50"
  defp icon_bg(_status), do: "bg-tymeslot-200"

  defp icon_color(:active), do: "text-turquoise-600"
  defp icon_color(:pending_link), do: "text-amber-600"
  defp icon_color(:auto_disabled), do: "text-red-400"
  defp icon_color(_status), do: "text-tymeslot-400"

  defp event_tag_style(:active), do: "bg-turquoise-50 text-turquoise-700 border-turquoise-200"
  defp event_tag_style(_status), do: "bg-tymeslot-100 text-tymeslot-500 border-tymeslot-200"

  defp event_dot_style(:active), do: "bg-turquoise-500"
  defp event_dot_style(_status), do: "bg-tymeslot-400"

  defp truncate_chat_id(chat_id) when is_binary(chat_id) do
    if String.length(chat_id) > 12 do
      String.slice(chat_id, 0, 12) <> "..."
    else
      chat_id
    end
  end
end
