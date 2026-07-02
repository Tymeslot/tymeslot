defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.TabNav do
  @moduledoc """
  Category tab navigation for the unified integrations hub.

  Renders one patch link per tab with an active turquoise underline, an
  optional count pill, and a small coloured status dot when the tab is not
  healthy (`status != :ok`). Dot colours mirror `UIComponents.status_badge/1`.
  """
  use Phoenix.Component
  use TymeslotWeb, :verified_routes

  attr :active_tab, :atom, required: true
  attr :tabs, :list, required: true

  @spec integrations_tab_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def integrations_tab_nav(assigns) do
    ~H"""
    <div role="tablist" class="flex gap-1 border-b border-tymeslot-200">
      <.link
        :for={tab <- @tabs}
        patch={~p"/dashboard/integrations?tab=#{tab.id}"}
        role="tab"
        aria-selected={to_string(tab.id == @active_tab)}
        class={[
          "flex items-center gap-2 px-4 py-2.5 text-token-sm font-semibold -mb-px border-b-2",
          (tab.id == @active_tab && "text-turquoise-700 border-turquoise-500") ||
            "text-tymeslot-500 border-transparent hover:text-tymeslot-700"
        ]}
      >
        {tab.label}
        <span
          :if={tab.count}
          class="text-token-xs rounded-token-full bg-tymeslot-100 px-1.5 py-0.5 font-semibold text-tymeslot-600"
        >
          {tab.count}
        </span>
        <span
          :if={tab.status != :ok}
          class={["h-1.5 w-1.5 rounded-token-full", dot(tab.status)]}
          aria-hidden="true"
        />
      </.link>
    </div>
    """
  end

  defp dot(:warning), do: "bg-amber-500"
  defp dot(:error), do: "bg-red-500"
  defp dot(_), do: "bg-transparent"
end
