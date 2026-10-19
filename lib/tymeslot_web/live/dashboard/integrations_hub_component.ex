defmodule TymeslotWeb.Dashboard.IntegrationsHubComponent do
  @moduledoc "Unified integrations dashboard: Calendars, Video, Payments tabs."
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
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
    health_states = HealthCheck.health_states_for_user(user_id)
    stuck_changes = Calendar.stuck_changes(user_id)
    connect_account = load_connect_account(payments_allowed?, user_id)
    payment_state = MeetingPayments.connect_display_state(connect_account)

    # A single attention list drives both the aggregated banner and the
    # per-tab status dots — one source of truth for "what needs attention".
    attention = attention_items(calendars, videos, health_states, stuck_changes, payment_state)

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
     |> assign(:stuck_changes, stuck_changes)
     |> assign(:connect_account, connect_account)
     |> assign(:active_tab, parse_tab(assigns[:params], payments_allowed?))}
  end

  # ── Summary data loading ──────────────────────────────────────────

  defp load_connect_account(false, _user_id), do: nil

  defp load_connect_account(true, user_id),
    do: MeetingPayments.get_connect_account_for_user(user_id)

  # ── Tabs ──────────────────────────────────────────────────────────

  defp build_tabs(calendars, videos, attention, payments_allowed?) do
    [
      tab(:calendars, dgettext("dashboard_integrations", "Calendars"), calendars, attention),
      tab(:video, dgettext("dashboard_integrations", "Video"), videos, attention)
    ] ++ payments_tab(payments_allowed?, attention)
  end

  defp payments_tab(false, _attention), do: []

  defp payments_tab(true, attention),
    do: [tab(:payments, dgettext("dashboard_integrations", "Payments"), nil, attention)]

  # Each tab is a link to its own URL, carrying a count of what is connected
  # and, when something in it needs attention, a dot in the same tone as the
  # status pills on its rows.
  defp tab(id, label, integrations, attention) do
    status = worst_status(for i <- attention, i.tab == id, do: i)

    %{
      id: id,
      label: label,
      patch: ~p"/dashboard/integrations?tab=#{id}",
      count: count_badge(integrations),
      status: if(status != :ok, do: UIComponents.status_tone(status)),
      status_label: if(status != :ok, do: status_hint(status))
    }
  end

  defp status_hint(status),
    do:
      dgettext("dashboard_integrations", "%{status} - needs attention",
        status: status_word(status)
      )

  defp status_word(:warning), do: dgettext("dashboard_integrations", "Warning")
  defp status_word(:error), do: dgettext("dashboard_integrations", "Error")

  # A `0` badge is noise; only show a count once at least one is connected.
  defp count_badge(nil), do: nil
  defp count_badge([]), do: nil
  defp count_badge(list), do: length(list)

  # ── Attention aggregation ─────────────────────────────────────────

  defp attention_items(calendars, videos, health_states, stuck_changes, payment_state) do
    # Each item records the connection it is about, so the banner counts
    # connections, however many items one of them has.
    items =
      integration_attention(calendars, health_states.calendar, stuck_changes, :calendars) ++
        integration_attention(videos, health_states.video, %{}, :video) ++
        Enum.map(payment_attention(payment_state), &Map.put(&1, :source, :payments))

    Enum.sort_by(items, &severity_rank(&1.severity))
  end

  defp integration_attention(integrations, health_states, stuck_changes, tab) do
    Enum.flat_map(integrations, fn integration ->
      integration
      |> attention_for(health_states, stuck_changes, tab)
      |> Enum.map(&Map.put(&1, :source, {tab, integration.id}))
    end)
  end

  # Delegates precedence (paused → needs_reauth → unhealthy → healthy) to the
  # canonical `HealthCheck.attention_status/2` classifier, the same one the
  # per-row badges use, so the two can never drift.
  defp attention_for(integration, health_states, stuck_changes, tab) do
    health = Map.get(health_states, integration.id)

    # Removed calendars are listed whatever the connection's state, since
    # the owner dismisses them from the card and must see what that clears.
    connection_attention(integration, health, stuck_changes, tab) ++
      removed_attention(integration, tab)
  end

  defp connection_attention(integration, health, stuck_changes, tab) do
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

      :ok ->
        room_creation_attention(integration, tab) ++
          stuck_attention(Map.get(stuck_changes, integration.id), integration, tab)

      _paused ->
        []
    end
  end

  # A connection the provider accepts but whose rooms it refuses is the one
  # problem `attention_status/2` cannot see: the credentials are fine, so the
  # integration classifies as healthy. Its row says so with its own badge and
  # notice, and this puts the same thing in the banner, which is otherwise the
  # only place the refusal never reaches its owner. Only for an otherwise
  # healthy integration, exactly as the row's badge is, so a paused or
  # unreachable one still reports the worse problem first.
  defp room_creation_attention(%{room_creation_error: nil}, _tab), do: []

  defp room_creation_attention(%{room_creation_error: _code} = integration, tab),
    do: [
      %{
        tab: tab,
        severity: :warning,
        message:
          dgettext("dashboard_integrations", "%{name}: new bookings get no video link.",
            name: integration.name
          )
      }
    ]

  # Calendar integrations have no such field, and so no such refusal.
  defp room_creation_attention(_integration, _tab), do: []

  # CalDAV changes made in Tymeslot that the server kept refusing are no
  # longer sent (`Calendar.stuck_changes/1`), so the calendar differs from the
  # grid until the owner retries them from the calendar's card. Listed only
  # for an integration with nothing worse to report: a paused one or one
  # waiting to be reconnected gets its own line, and its card offers no
  # retry until that is resolved.
  defp stuck_attention(nil, _integration, _tab), do: []

  defp stuck_attention(%{count: count}, integration, tab),
    do: [
      %{
        tab: tab,
        severity: :warning,
        message:
          dngettext(
            "dashboard_integrations",
            "%{name}: 1 change made here was not saved to the calendar.",
            "%{name}: %{count} changes made here were not saved to the calendar.",
            count,
            name: integration.name
          )
      }
    ]

  # A calendar the server stopped listing, until its owner dismisses the
  # notice on the calendar's card. Only calendar integrations record them.
  defp removed_attention(%{removed_calendars: [%{name: calendar}]} = integration, tab),
    do: [
      %{
        tab: tab,
        severity: :warning,
        message:
          dgettext(
            "dashboard_integrations",
            "%{name}: “%{calendar}” is no longer on your calendar server, so Tymeslot has stopped using it.",
            name: integration.name,
            calendar: calendar
          )
      }
    ]

  defp removed_attention(%{removed_calendars: [_first | _rest] = removed} = integration, tab),
    do: [
      %{
        tab: tab,
        severity: :warning,
        message:
          dngettext(
            "dashboard_integrations",
            "%{name}: %{count} calendar is no longer on your calendar server, so Tymeslot has stopped using it.",
            "%{name}: %{count} calendars are no longer on your calendar server, so Tymeslot has stopped using them.",
            length(removed),
            name: integration.name
          )
      }
    ]

  defp removed_attention(_integration, _tab), do: []

  defp payment_attention(:restricted),
    do: [
      %{
        tab: :payments,
        severity: :error,
        message: dgettext("dashboard_integrations", "Your Stripe account is restricted.")
      }
    ]

  defp payment_attention(:unsupported_currency),
    do: [
      %{
        tab: :payments,
        severity: :warning,
        message:
          dgettext(
            "dashboard_integrations",
            "Your Stripe account's currency is not supported. Choose another to take payments."
          )
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
    count = attention |> Enum.uniq_by(& &1.source) |> length()

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
    <div id="integrations-hub">
      <.dashboard_page icon="hero-puzzle-piece" title={dgettext("dashboard_common", "Integrations")}>
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

        <.tab_bar
          id="integrations-tabs"
          active_tab={@active_tab}
          tabs={@tabs}
          aria_label={dgettext("dashboard_integrations", "Integration categories")}
        />
        <div data-tab-panel={@active_tab}>
          <.live_component
            :if={@active_tab == :calendars}
            module={CalendarSettingsComponent}
            id="calendar-settings"
            current_user={@current_user}
            integration_status={@integration_status}
            client_ip={@client_ip}
            user_agent={@user_agent}
            integrations={@calendars}
            health_states={@health_states.calendar}
            stuck_changes={@stuck_changes}
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
      </.dashboard_page>
    </div>
    """
  end
end
