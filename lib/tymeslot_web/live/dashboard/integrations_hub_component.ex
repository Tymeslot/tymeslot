defmodule TymeslotWeb.Dashboard.IntegrationsHubComponent do
  @moduledoc "Unified integrations dashboard: Calendars, Video, Payments tabs."
  use TymeslotWeb, :live_component

  import TymeslotWeb.Components.Dashboard.Integrations.Shared.TabNav

  alias TymeslotWeb.Dashboard.CalendarSettingsComponent
  alias TymeslotWeb.Dashboard.VideoSettingsComponent

  @tab_labels %{calendars: "Calendars", video: "Video", payments: "Payments"}

  @impl Phoenix.LiveComponent
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

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="integrations-hub" class="space-y-8 pb-20">
      <div class="flex items-start justify-between gap-4 flex-wrap">
        <.section_header title="Integrations" />

        <div class="flex items-center gap-2">
          <span class="text-token-sm font-semibold text-tymeslot-500 mr-1">Add integration</span>
          <.link
            patch={~p"/dashboard/integrations?tab=calendars"}
            class="inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-500 px-3 py-2 text-token-sm font-semibold text-white transition-colors hover:bg-turquoise-600"
          >
            <.icon name="hero-calendar-days" class="w-4 h-4" /> Connect a calendar
          </.link>
          <.link
            patch={~p"/dashboard/integrations?tab=video"}
            class="inline-flex items-center gap-1.5 rounded-token-lg border border-turquoise-200 bg-white px-3 py-2 text-token-sm font-semibold text-turquoise-700 transition-colors hover:bg-turquoise-50"
          >
            <.icon name="hero-video-camera" class="w-4 h-4" /> Connect a video tool
          </.link>
        </div>
      </div>

      <.integrations_tab_nav active_tab={@active_tab} tabs={@tabs} />
      <div data-tab-panel={@active_tab}>
        <.live_component
          :if={@active_tab == :calendars}
          module={CalendarSettingsComponent}
          id="calendar-settings"
          current_user={@current_user}
          integration_status={@integration_status}
          client_ip={@client_ip}
          user_agent={@user_agent}
        />
        <.live_component
          :if={@active_tab == :video}
          module={VideoSettingsComponent}
          id="video-settings"
          current_user={@current_user}
          integration_status={@integration_status}
          client_ip={@client_ip}
          user_agent={@user_agent}
        />
        <p :if={@active_tab == :payments} class="text-tymeslot-500">
          Coming online: {@tab_labels[@active_tab]}.
        </p>
      </div>
    </div>
    """
  end
end
