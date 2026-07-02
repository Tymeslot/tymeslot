defmodule TymeslotWeb.Dashboard.IntegrationsHubComponent do
  @moduledoc "Unified integrations dashboard: Calendars, Video, Payments tabs."
  use TymeslotWeb, :live_component

  import TymeslotWeb.Components.Dashboard.Integrations.Shared.TabNav

  alias TymeslotWeb.Dashboard.CalendarSettingsComponent
  alias TymeslotWeb.Dashboard.PaymentsSettingsComponent
  alias TymeslotWeb.Dashboard.VideoSettingsComponent

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # `payments_allowed` is computed once at mount by `DashboardInitHook`
    # (mirroring the `PaymentsHandlers` gate: `:ok`/`:stripe_required` allow),
    # so the hub reuses it rather than re-checking the feature here.
    payments_allowed? = Map.get(assigns, :payments_allowed, false)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:tabs, build_tabs(payments_allowed?))
     |> assign(:active_tab, parse_tab(assigns[:params], payments_allowed?))}
  end

  # Real counts and health status arrive in a later task; for now every tab is
  # healthy with no count. The Payments tab appears only when the host can
  # access the `:meeting_payments` feature.
  defp build_tabs(payments_allowed?) do
    [
      %{id: :calendars, label: "Calendars", count: nil, status: :ok},
      %{id: :video, label: "Video", count: nil, status: :ok}
      # Deferred to Task 9 (attention banner): derive the Payments tab status
      # from the connect account's display state (`:ready`→`:ok`,
      # `:restricted`→`:error`, `:pending_review`/`:incomplete`→`:warning`).
      # Until health is wired through it stays `:ok`, matching calendars/video.
    ] ++ payments_tab(payments_allowed?)
  end

  defp payments_tab(true),
    do: [%{id: :payments, label: "Payments", count: nil, status: :ok}]

  defp payments_tab(false), do: []

  # `?tab=payments` is only honoured when the host may access payments;
  # otherwise it falls back to calendars rather than rendering a gated tab.
  defp parse_tab(%{"tab" => "payments"}, false), do: :calendars

  defp parse_tab(%{"tab" => tab}, _payments_allowed?)
       when tab in ~w(calendars video payments),
       do: String.to_existing_atom(tab)

  defp parse_tab(_params, _payments_allowed?), do: :calendars

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
        <.live_component
          :if={@active_tab == :payments}
          module={PaymentsSettingsComponent}
          id="payments-settings"
          current_user={@current_user}
        />
      </div>
    </div>
    """
  end
end
