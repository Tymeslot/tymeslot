defmodule TymeslotWeb.Dashboard.AnalyticsLive do
  @moduledoc """
  Built-in attribution dashboard for booking-page traffic.

  Shows visits, unique visitors, bookings and conversion rate for the
  signed-in user over a configurable date range (7/30/90 days), plus a
  per-source attribution table and a visits-over-time chart.

  All data is read through `Tymeslot.Analytics`; no Ecto queries live in
  this module.
  """
  use TymeslotWeb, :live_view

  alias Tymeslot.Analytics
  alias TymeslotWeb.Components.DashboardLayout
  alias TymeslotWeb.Dashboard.AnalyticsLive.SourcesTable
  alias TymeslotWeb.Dashboard.AnalyticsLive.SummaryCards
  alias TymeslotWeb.Dashboard.AnalyticsLive.VisitsChart

  @ranges %{"7d" => 7, "30d" => 30, "90d" => 90}
  @default_range "30d"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if Analytics.enabled?() do
      {:ok, assign_default_range(socket)}
    else
      {:ok,
       socket
       |> put_flash(:info, "Booking analytics is not enabled on this installation.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      {:noreply, load_data(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("set_range", %{"range" => range}, socket) when is_map_key(@ranges, range) do
    {:noreply,
     socket
     |> assign(:range, range)
     |> assign_window_for(range)
     |> load_data()}
  end

  def handle_event("set_range", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <DashboardLayout.dashboard_layout
      current_user={@current_user}
      profile={@profile}
      current_action={:analytics}
      integration_status={@integration_status}
      automations_allowed={@automations_allowed}
      sidebar_extensions={@sidebar_extensions}
      unseen_announcements={@unseen_announcements}
    >
      <div class="space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-black tracking-tight text-tymeslot-900">
            Analytics
          </h1>
          <div class="flex gap-2" role="group" aria-label="Date range">
            <.range_button label="7 days" value="7d" current={@range} />
            <.range_button label="30 days" value="30d" current={@range} />
            <.range_button label="90 days" value="90d" current={@range} />
          </div>
        </div>

        <SummaryCards.cards
          visits={@visits}
          unique_visitors={@unique_visitors}
          bookings={@bookings}
        />

        <VisitsChart.chart
          points={@visits_by_day}
          from={@from}
          to={@to}
          time_zone={@time_zone}
        />

        <SourcesTable.table sources={@sources} />
      </div>
    </DashboardLayout.dashboard_layout>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :current, :string, required: true

  defp range_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_range"
      phx-value-range={@value}
      aria-pressed={@current == @value}
      class={[
        "rounded-md px-3 py-1.5 text-token-sm font-semibold transition-colors",
        if(@current == @value,
          do: "bg-turquoise-500 text-white shadow-sm",
          else: "bg-tymeslot-50 text-tymeslot-700 hover:bg-tymeslot-100"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  defp assign_default_range(socket) do
    socket
    |> assign(:range, @default_range)
    |> assign_window_for(@default_range)
    |> assign(
      visits: 0,
      unique_visitors: 0,
      bookings: 0,
      sources: [],
      visits_by_day: []
    )
  end

  defp assign_window_for(socket, range) do
    days = Map.get(@ranges, range, @ranges[@default_range])
    now = DateTime.utc_now()
    from = DateTime.add(now, -days * 86_400, :second)
    assign(socket, from: from, to: now, time_zone: organizer_time_zone(socket))
  end

  defp organizer_time_zone(socket) do
    case socket.assigns do
      %{profile: %{timezone: tz}} when is_binary(tz) and tz != "" -> tz
      _assigns -> "Etc/UTC"
    end
  end

  defp load_data(
         %{assigns: %{current_user: user, from: from, to: to, time_zone: time_zone}} = socket
       ) do
    visits = Analytics.count_visits(user.id, from, to)
    unique_visitors = Analytics.count_unique_visitors(user.id, from, to)
    bookings = Analytics.count_bookings(user.id, from, to)
    visits_by_day = Analytics.visits_by_day(user.id, from, to, time_zone)
    sources = Analytics.attribution_table(user.id, from, to)

    assign(socket,
      visits: visits,
      unique_visitors: unique_visitors,
      bookings: bookings,
      visits_by_day: visits_by_day,
      sources: sources
    )
  end
end
