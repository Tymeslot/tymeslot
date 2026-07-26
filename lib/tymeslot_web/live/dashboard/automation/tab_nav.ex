defmodule TymeslotWeb.Dashboard.Automation.TabNav do
  @moduledoc """
  Tab bar for `TymeslotWeb.Dashboard.AutomationSettingsComponent`.

  Renders one button per integration channel and pushes `switch_tab` back to the
  owning LiveComponent through the `:myself` target passed in by the caller.
  Telegram renders as a disabled placeholder when the integration is switched
  off; Slack is omitted entirely.
  """
  use TymeslotWeb, :html

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
        <span>Webhooks</span>
      </button>

      <%= if @telegram_enabled do %>
        <button
          phx-click={JS.push("switch_tab", value: %{"tab" => "telegram"}, target: @myself)}
          class={tab_class(@active_tab == :telegram)}
        >
          <svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
            <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
          </svg>
          <span>Telegram</span>
        </button>
      <% else %>
        <div class="flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-transparent border-transparent text-tymeslot-400 opacity-60 cursor-not-allowed">
          <svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
            <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
          </svg>
          <span>Telegram</span>
          <span class="ml-2 text-token-2xs bg-tymeslot-100 px-2 py-0.5 rounded-full uppercase tracking-tighter">Disabled</span>
        </div>
      <% end %>

      <%= if @slack_enabled do %>
        <button
          phx-click={JS.push("switch_tab", value: %{"tab" => "slack"}, target: @myself)}
          class={tab_class(@active_tab == :slack)}
        >
          <svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
            <path d="M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z" />
          </svg>
          <span>Slack</span>
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
