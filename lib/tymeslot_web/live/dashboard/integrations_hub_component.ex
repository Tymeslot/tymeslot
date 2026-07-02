defmodule TymeslotWeb.Dashboard.IntegrationsHubComponent do
  @moduledoc "Unified integrations dashboard: Calendars, Video, Payments tabs."
  use TymeslotWeb, :live_component

  @tabs [:calendars, :video, :payments]
  @tab_labels %{calendars: "Calendars", video: "Video", payments: "Payments"}

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:tabs, @tabs)
     |> assign(:tab_labels, @tab_labels)
     |> assign(:active_tab, parse_tab(assigns[:params]))}
  end

  defp parse_tab(%{"tab" => tab}) when tab in ~w(calendars video payments),
    do: String.to_existing_atom(tab)

  defp parse_tab(_params), do: :calendars

  @impl true
  def render(assigns) do
    ~H"""
    <div id="integrations-hub" class="space-y-8 pb-20">
      <.section_header title="Integrations" />
      <div role="tablist" class="flex gap-1 border-b border-tymeslot-200">
        <%!-- Placeholder tab labels; real nav with patch links + status dots comes in Task 3. --%>
        <span
          :for={tab <- @tabs}
          role="tab"
          class="px-4 py-2.5 text-token-sm font-semibold"
        >
          {@tab_labels[tab]}
        </span>
      </div>
      <div data-tab-panel={@active_tab}>
        <p class="text-tymeslot-500">Coming online: {@tab_labels[@active_tab]}.</p>
      </div>
    </div>
    """
  end
end
