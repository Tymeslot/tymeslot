defmodule TymeslotWeb.Dashboard.IntegrationsHubComponent do
  @moduledoc "Unified integrations dashboard: Calendars, Video, Payments tabs."
  use TymeslotWeb, :live_component

  import TymeslotWeb.Components.Dashboard.Integrations.Shared.TabNav

  @tab_labels %{calendars: "Calendars", video: "Video", payments: "Payments"}

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:tabs, build_tabs())
     |> assign(:tab_labels, @tab_labels)
     |> assign(:active_tab, parse_tab(assigns[:params]))}
  end

  # Real counts and health status arrive in a later task; for now every tab is
  # healthy with no count.
  defp build_tabs do
    [
      %{id: :calendars, label: "Calendars", count: nil, status: :ok},
      %{id: :video, label: "Video", count: nil, status: :ok},
      %{id: :payments, label: "Payments", count: nil, status: :ok}
    ]
  end

  defp parse_tab(%{"tab" => tab}) when tab in ~w(calendars video payments),
    do: String.to_existing_atom(tab)

  defp parse_tab(_params), do: :calendars

  @impl true
  def render(assigns) do
    ~H"""
    <div id="integrations-hub" class="space-y-8 pb-20">
      <.section_header title="Integrations" />
      <.integrations_tab_nav active_tab={@active_tab} tabs={@tabs} />
      <div data-tab-panel={@active_tab}>
        <p class="text-tymeslot-500">Coming online: {@tab_labels[@active_tab]}.</p>
      </div>
    </div>
    """
  end
end
