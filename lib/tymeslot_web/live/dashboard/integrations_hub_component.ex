defmodule TymeslotWeb.Dashboard.IntegrationsHubComponent do
  @moduledoc "Unified integrations dashboard: Calendars, Video, Payments tabs."
  use TymeslotWeb, :live_component

  import TymeslotWeb.Components.Dashboard.Integrations.Shared.TabNav

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent
  alias TymeslotWeb.Dashboard.PaymentsSettingsComponent
  alias TymeslotWeb.Dashboard.VideoSettingsComponent

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # `payments_allowed` is computed once at mount by `DashboardInitHook`
    # (mirroring the `PaymentsHandlers` gate: `:ok`/`:stripe_required` allow),
    # so the hub reuses it rather than re-checking the feature here.
    payments_allowed? = Map.get(assigns, :payments_allowed, false)
    socket = assign(socket, assigns)
    user_id = socket.assigns.current_user.id

    calendars = Calendar.list_integrations(user_id)
    videos = Video.list_integrations(user_id)
    unhealthy_ids = unhealthy_ids_by_type(user_id)
    payment_state = payment_display_state(payments_allowed?, user_id)

    # A single attention list drives both the aggregated banner and the
    # per-tab status dots — one source of truth for "what needs attention".
    attention = attention_items(calendars, videos, unhealthy_ids, payment_state)

    {:ok,
     socket
     |> assign(:tabs, build_tabs(calendars, videos, attention, payments_allowed?))
     |> assign(:attention, attention)
     |> assign(:active_tab, parse_tab(assigns[:params], payments_allowed?))}
  end

  # ── Summary data loading ──────────────────────────────────────────

  defp unhealthy_ids_by_type(user_id) do
    grouped =
      user_id
      |> IntegrationHealthStateQueries.list_unhealthy_for_user()
      |> Enum.group_by(& &1.integration_type, & &1.integration_id)

    %{
      calendars: MapSet.new(Map.get(grouped, "calendar", [])),
      video: MapSet.new(Map.get(grouped, "video", []))
    }
  end

  defp payment_display_state(false, _user_id), do: nil

  defp payment_display_state(true, user_id) do
    user_id
    |> MeetingPayments.get_connect_account_for_user()
    |> MeetingPayments.connect_display_state()
  end

  # ── Tabs ──────────────────────────────────────────────────────────

  defp build_tabs(calendars, videos, attention, payments_allowed?) do
    [
      %{
        id: :calendars,
        label: "Calendars",
        count: count_badge(calendars),
        status: worst_status(for i <- attention, i.tab == :calendars, do: i)
      },
      %{
        id: :video,
        label: "Video",
        count: count_badge(videos),
        status: worst_status(for i <- attention, i.tab == :video, do: i)
      }
    ] ++ payments_tab(payments_allowed?, attention)
  end

  defp payments_tab(false, _attention), do: []

  defp payments_tab(true, attention),
    do: [
      %{
        id: :payments,
        label: "Payments",
        count: nil,
        status: worst_status(for i <- attention, i.tab == :payments, do: i)
      }
    ]

  # A `0` badge is noise; only show a count once at least one is connected.
  defp count_badge([]), do: nil
  defp count_badge(list), do: length(list)

  # ── Attention aggregation ─────────────────────────────────────────

  defp attention_items(calendars, videos, unhealthy_ids, payment_state) do
    items =
      integration_attention(calendars, unhealthy_ids.calendars, :calendars) ++
        integration_attention(videos, unhealthy_ids.video, :video) ++
        payment_attention(payment_state)

    Enum.sort_by(items, &severity_rank(&1.severity))
  end

  defp integration_attention(integrations, unhealthy_ids, tab),
    do: Enum.flat_map(integrations, &attention_for(&1, unhealthy_ids, tab))

  # Paused integrations never raise attention; a stale credential (`needs_reauth`)
  # takes precedence over a failing health probe, mirroring the per-row badge.
  defp attention_for(%{is_active: true, needs_reauth: true} = integration, _ids, tab),
    do: [%{tab: tab, severity: :warning, message: "#{integration.name} needs reconnecting."}]

  defp attention_for(%{is_active: true, id: id} = integration, ids, tab) do
    if MapSet.member?(ids, id),
      do: [%{tab: tab, severity: :warning, message: "#{integration.name} stopped syncing."}],
      else: []
  end

  defp attention_for(_integration, _ids, _tab), do: []

  defp payment_attention(:restricted),
    do: [%{tab: :payments, severity: :error, message: "Your Stripe account is restricted."}]

  defp payment_attention(:pending_review),
    do: [
      %{tab: :payments, severity: :warning, message: "Stripe is still reviewing your account."}
    ]

  defp payment_attention(:incomplete),
    do: [
      %{
        tab: :payments,
        severity: :warning,
        message: "Finish connecting Stripe to accept payments."
      }
    ]

  defp payment_attention(_state), do: []

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1

  # `:ok` for an empty list keeps the tab dot hidden; the banner only renders
  # for a non-empty list, so it always receives a valid `:warning`/`:error`.
  defp worst_status([]), do: :ok

  defp worst_status(items) do
    if Enum.any?(items, &(&1.severity == :error)), do: :error, else: :warning
  end

  # Items are sorted worst-first, so the head carries the target tab.
  defp attention_headline(attention) do
    count = length(attention)
    "#{count} #{connection_word(count)} #{needs_word(count)} attention — #{hd(attention).message}"
  end

  defp connection_word(1), do: "connection"
  defp connection_word(_count), do: "connections"

  defp needs_word(1), do: "needs"
  defp needs_word(_count), do: "need"

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

      <%!--
        Aggregated attention banner: one line summarising the worst issue
        across all categories, with a jump link to the offending tab. Rendered
        only when something actually needs attention.
      --%>
      <.info_box :if={@attention != []} variant={worst_status(@attention)}>
        {attention_headline(@attention)}
        <.link
          patch={~p"/dashboard/integrations?tab=#{hd(@attention).tab}"}
          class="font-semibold underline hover:no-underline"
        >
          Review
        </.link>
      </.info_box>

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
