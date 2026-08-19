defmodule TymeslotWeb.Dashboard.IntegrationsHubComponent do
  @moduledoc "Unified integrations dashboard: Calendars, Video, Payments tabs."
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.Dashboard.Integrations.Shared.TabNav

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent
  alias TymeslotWeb.Dashboard.PaymentsSettingsComponent
  alias TymeslotWeb.Dashboard.VideoSettingsComponent

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # `payments_allowed` is computed once at mount by `DashboardInitHook`
    # through `Features.meeting_payments_allowed?/1`, so the hub reuses it
    # rather than re-checking the feature here.
    payments_allowed? = Map.get(assigns, :payments_allowed, false)
    socket = assign(socket, assigns)
    user_id = socket.assigns.current_user.id

    calendars = Calendar.list_integrations(user_id)
    videos = Video.list_integrations(user_id)
    health_states = health_states_by_type(user_id)
    connect_account = load_connect_account(payments_allowed?, user_id)
    payment_state = MeetingPayments.connect_display_state(connect_account)

    # A single attention list drives both the aggregated banner and the
    # per-tab status dots — one source of truth for "what needs attention".
    attention = attention_items(calendars, videos, health_states, payment_state)

    {:ok,
     socket
     |> assign(:tabs, build_tabs(calendars, videos, attention, payments_allowed?))
     |> assign(:attention, attention)
     # Handed down to the active tab's child component so it can reuse this
     # data instead of re-querying it in its own `update/2` — see the
     # `integrations`/`health_states`/`connect_account` props below.
     |> assign(:calendars, calendars)
     |> assign(:videos, videos)
     |> assign(:health_states, health_states)
     |> assign(:connect_account, connect_account)
     |> assign(:active_tab, parse_tab(assigns[:params], payments_allowed?))}
  end

  # ── Summary data loading ──────────────────────────────────────────

  # Builds the same `%{integration_id => health_state}` shape the per-row
  # calendar/video settings components use, so the hub's attention
  # classification and the row badges are derived from one health source.
  defp health_states_by_type(user_id) do
    grouped =
      user_id
      |> HealthCheck.list_unhealthy_for_user()
      |> Enum.group_by(& &1.integration_type)
      |> Map.new(fn {type, records} ->
        {type, Map.new(records, &{&1.integration_id, Monitor.from_db_record(&1)})}
      end)

    %{
      calendars: Map.get(grouped, "calendar", %{}),
      video: Map.get(grouped, "video", %{})
    }
  end

  defp load_connect_account(false, _user_id), do: nil

  defp load_connect_account(true, user_id),
    do: MeetingPayments.get_connect_account_for_user(user_id)

  # ── Tabs ──────────────────────────────────────────────────────────

  defp build_tabs(calendars, videos, attention, payments_allowed?) do
    [
      %{
        id: :calendars,
        label: dgettext("dashboard_integrations", "Calendars"),
        count: count_badge(calendars),
        status: worst_status(for i <- attention, i.tab == :calendars, do: i)
      },
      %{
        id: :video,
        label: dgettext("dashboard_integrations", "Video"),
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
        label: dgettext("dashboard_integrations", "Payments"),
        count: nil,
        status: worst_status(for i <- attention, i.tab == :payments, do: i)
      }
    ]

  # A `0` badge is noise; only show a count once at least one is connected.
  defp count_badge([]), do: nil
  defp count_badge(list), do: length(list)

  # ── Attention aggregation ─────────────────────────────────────────

  defp attention_items(calendars, videos, health_states, payment_state) do
    items =
      integration_attention(calendars, health_states.calendars, :calendars) ++
        integration_attention(videos, health_states.video, :video) ++
        payment_attention(payment_state)

    Enum.sort_by(items, &severity_rank(&1.severity))
  end

  defp integration_attention(integrations, health_states, tab),
    do: Enum.flat_map(integrations, &attention_for(&1, health_states, tab))

  # Delegates precedence (paused → needs_reauth → unhealthy → healthy) to the
  # canonical `HealthCheck.attention_status/2` classifier, the same one the
  # per-row badges use, so the two can never drift.
  defp attention_for(integration, health_states, tab) do
    health = Map.get(health_states, integration.id)

    case HealthCheck.attention_status(integration, health) do
      :needs_reauth ->
        [
          %{
            tab: tab,
            severity: :warning,
            message:
              dgettext("dashboard_integrations", "%{name} needs reconnecting.",
                name: integration.name
              )
          }
        ]

      :unhealthy ->
        [
          %{
            tab: tab,
            severity: :warning,
            message:
              dgettext("dashboard_integrations", "%{name} stopped syncing.",
                name: integration.name
              )
          }
        ]

      _no_attention ->
        []
    end
  end

  defp payment_attention(:restricted),
    do: [
      %{
        tab: :payments,
        severity: :error,
        message: dgettext("dashboard_integrations", "Your Stripe account is restricted.")
      }
    ]

  defp payment_attention(:pending_review),
    do: [
      %{
        tab: :payments,
        severity: :warning,
        message: dgettext("dashboard_integrations", "Stripe is still reviewing your account.")
      }
    ]

  defp payment_attention(:incomplete),
    do: [
      %{
        tab: :payments,
        severity: :warning,
        message:
          dgettext("dashboard_integrations", "Finish connecting Stripe to accept payments.")
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

    dngettext(
      "dashboard_integrations",
      "%{count} connection needs attention - %{message}",
      "%{count} connections need attention - %{message}",
      count,
      count: count,
      message: hd(attention).message
    )
  end

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
      <.section_header title={dgettext("dashboard_integrations", "Integrations")} />

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
          {dgettext("dashboard_integrations", "Review")}
        </.link>
      </.info_box>

      <.integrations_tab_nav active_tab={@active_tab} tabs={@tabs} />
      <div
        role="tabpanel"
        id={"tab-panel-#{@active_tab}"}
        aria-labelledby={"tab-#{@active_tab}"}
        data-tab-panel={@active_tab}
      >
        <.live_component
          :if={@active_tab == :calendars}
          module={CalendarSettingsComponent}
          id="calendar-settings"
          current_user={@current_user}
          integration_status={@integration_status}
          client_ip={@client_ip}
          user_agent={@user_agent}
          integrations={@calendars}
          health_states={@health_states.calendars}
        />
        <.live_component
          :if={@active_tab == :video}
          module={VideoSettingsComponent}
          id="video-settings"
          current_user={@current_user}
          integration_status={@integration_status}
          client_ip={@client_ip}
          user_agent={@user_agent}
          integrations={@videos}
          health_states={@health_states.video}
        />
        <.live_component
          :if={@active_tab == :payments}
          module={PaymentsSettingsComponent}
          id="payments-settings"
          current_user={@current_user}
          connect_account={@connect_account}
        />
      </div>
    </div>
    """
  end
end
