defmodule TymeslotWeb.Dashboard.Automation.TabNav do
  @moduledoc """
  Tab bar for `TymeslotWeb.Dashboard.AutomationSettingsComponent`.

  Renders one button per integration channel and pushes `switch_tab` back to the
  owning LiveComponent through the `:myself` target passed in by the caller.
  Telegram renders as a disabled placeholder when the integration is switched
  off; Slack is omitted entirely.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Icons.IconComponents

  attr :active_tab, :atom, required: true
  attr :telegram_enabled, :boolean, required: true
  attr :slack_enabled, :boolean, required: true
  attr :myself, :any, required: true

  @spec tab_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def tab_nav(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-4 bg-tymeslot-50/50 p-2 rounded-[2rem] border-2 border-tymeslot-50 mb-10">
      <button
        phx-click={JS.push("switch_tab", value: %{"tab" => "webhooks"}, target: @myself)}
        class={tab_class(@active_tab == :webhooks)}
      >
        <IconComponents.icon name={:webhook} class="w-5 h-5" />
        <span>{dgettext("dashboard_automation", "Webhooks")}</span>
      </button>

      <%= if @telegram_enabled do %>
        <button
          phx-click={JS.push("switch_tab", value: %{"tab" => "telegram"}, target: @myself)}
          class={tab_class(@active_tab == :telegram)}
        >
          <IconComponents.icon name={:telegram} class="w-5 h-5" />
          <span>{dgettext("dashboard_automation", "Telegram")}</span>
        </button>
      <% else %>
        <div class="flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-transparent border-transparent text-tymeslot-400 opacity-60 cursor-not-allowed">
          <IconComponents.icon name={:telegram} class="w-5 h-5" />
          <span>{dgettext("dashboard_automation", "Telegram")}</span>
          <span class="ml-2 text-token-2xs bg-tymeslot-100 px-2 py-0.5 rounded-full uppercase tracking-tighter">
            {dgettext("dashboard_automation_chat", "Disabled")}
          </span>
        </div>
      <% end %>

      <%= if @slack_enabled do %>
        <button
          phx-click={JS.push("switch_tab", value: %{"tab" => "slack"}, target: @myself)}
          class={tab_class(@active_tab == :slack)}
        >
          <IconComponents.icon name={:slack} class="w-5 h-5" />
          <span>{dgettext("dashboard_automation", "Slack")}</span>
        </button>
      <% end %>
    </div>
    """
  end

  defp tab_class(true) do
    "flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-white border-white text-turquoise-600 shadow-xl shadow-tymeslot-200/50 scale-[1.02] cursor-default"
  end

  defp tab_class(false) do
    "flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-transparent border-transparent text-tymeslot-400 hover:text-tymeslot-600 hover:bg-white/50 cursor-pointer"
  end
end
