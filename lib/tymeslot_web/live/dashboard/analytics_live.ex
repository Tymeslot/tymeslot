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
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Analytics
  alias Tymeslot.Analytics.MetricsCache
  alias TymeslotWeb.Components.DashboardLayout
  alias TymeslotWeb.Dashboard.AnalyticsLive.DeviceBreakdown
  alias TymeslotWeb.Dashboard.AnalyticsLive.SourcesTable
  alias TymeslotWeb.Dashboard.AnalyticsLive.SummaryCards
  alias TymeslotWeb.Dashboard.AnalyticsLive.VisitsChart
  alias TymeslotWeb.Dashboard.ComponentDispatch
  alias TymeslotWeb.Helpers.LocaleFormat

  @ranges %{"7d" => 7, "30d" => 30, "90d" => 90}
  @default_range "30d"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    cond do
      not Analytics.enabled?() ->
        {:ok,
         socket
         |> put_flash(
           :info,
           dgettext(
             "dashboard_analytics",
             "Booking analytics is not enabled on this installation."
           )
         )
         |> push_navigate(to: ~p"/dashboard")}

      # Data is still collected for this organizer (collection is ungated); the
      # dashboard itself is a paid feature, so a free user sees the upgrade
      # prompt instead and no metrics are computed. `analytics_allowed` is set
      # by the feature-assigns hook chain (default `true` in Core; SaaS overrides
      # it per subscription).
      not analytics_allowed?(socket) ->
        {:ok, socket}

      true ->
        {:ok, assign_default_range(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    if connected?(socket) and analytics_allowed?(socket) do
      {:noreply, load_data(socket)}
    else
      {:noreply, socket}
    end
  end

  defp analytics_allowed?(socket), do: Map.get(socket.assigns, :analytics_allowed, true)

  @impl Phoenix.LiveView
  def handle_event("set_range", %{"range" => range}, socket) when is_map_key(@ranges, range) do
    {:noreply,
     socket
     |> assign(:range, range)
     |> assign_window_for(range)
     |> load_data()}
  end

  def handle_event("set_range", _params, socket), do: {:noreply, socket}

  # Metrics are cached for 60s, so a just-recorded visit may not show on a plain
  # reload. Refresh drops the cache entry and recomputes, giving the organizer an
  # explicit way to see fresh numbers without waiting out the TTL. The window end
  # is re-derived to *now* as well, so a visit made after the dashboard was opened
  # (it would otherwise fall past the mount-time `to`) is included.
  def handle_event("refresh", _params, %{assigns: %{current_user: user, range: range}} = socket) do
    MetricsCache.invalidate(user.id, range)
    # Data reloads immediately; the spin is held briefly so the refresh is
    # perceptible even when the recompute returns in a few milliseconds.
    Process.send_after(self(), :stop_refresh_spin, 600)

    {:noreply,
     socket
     |> assign(:refreshing?, true)
     |> assign_window_for(range)
     |> load_data()}
  end

  @impl Phoenix.LiveView
  def handle_info(:stop_refresh_spin, socket) do
    {:noreply, assign(socket, :refreshing?, false)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <DashboardLayout.dashboard_layout
      current_user={@current_user}
      profile={@profile}
      current_action={:analytics}
      integration_status={@integration_status}
      automations_allowed={@automations_allowed}
      analytics_allowed={@analytics_allowed}
      sidebar_extensions={@sidebar_extensions}
      unseen_announcements={@unseen_announcements}
    >
      <ComponentDispatch.feature_placeholder
        :if={!@analytics_allowed}
        section={:analytics}
        current_user={@current_user}
        feature_placeholder_components={@feature_placeholder_components}
      />

      <div :if={@analytics_allowed} class="space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-black tracking-tight text-tymeslot-900">
            {dgettext("dashboard_analytics", "Analytics")}
          </h1>
          <div class="flex items-center gap-2">
            <div
              class="flex gap-2"
              role="group"
              aria-label={dgettext("dashboard_analytics", "Date range")}
            >
              <.range_button
                label={dgettext("dashboard_analytics", "7 days")}
                value="7d"
                current={@range}
              />
              <.range_button
                label={dgettext("dashboard_analytics", "30 days")}
                value="30d"
                current={@range}
              />
              <.range_button
                label={dgettext("dashboard_analytics", "90 days")}
                value="90d"
                current={@range}
              />
            </div>
            <button
              type="button"
              phx-click="refresh"
              title={dgettext("dashboard_analytics", "Refresh")}
              aria-label={dgettext("dashboard_analytics", "Refresh analytics")}
              class="rounded-md bg-tymeslot-50 p-2 text-tymeslot-700 transition-colors hover:bg-tymeslot-100"
            >
              <.icon name="hero-arrow-path" class={"h-4 w-4 #{if @refreshing?, do: "animate-spin"}"} />
            </button>
          </div>
        </div>

        <p
          :if={@loaded? and @refreshed_at}
          class="text-token-xs tabular-nums text-tymeslot-400"
          aria-live="polite"
        >
          {dgettext("dashboard_analytics", "Updated %{time}",
            time: format_refreshed_at(@refreshed_at, @time_zone)
          )}
        </p>

        <div
          :if={@partial_window?}
          class="flex items-start gap-2 rounded-token-lg bg-turquoise-50 px-4 py-3 text-token-sm text-tymeslot-700"
        >
          <.icon name="hero-information-circle" class="mt-0.5 h-5 w-5 shrink-0 text-turquoise-500" />
          <span>
            {dgettext(
              "dashboard_analytics",
              "Booking analytics started collecting on %{date}. Dates before then show no data, so longer ranges will look sparse until more history builds up.",
              date: format_launch_date(@launch_date)
            )}
          </span>
        </div>

        <SummaryCards.cards
          visits={@visits}
          unique_visitors={@unique_visitors}
          bookings={@bookings}
          converting_visitors={@converting_visitors}
          loading?={!@loaded?}
        />

        <p class="text-token-xs leading-relaxed text-tymeslot-400">
          <%!--
            Be honest about the cookieless model: the daily-rotated fingerprint
            means a visitor is counted once per UTC day, so multi-day "unique
            visitors" is a sum of daily uniques rather than truly distinct
            people, and conversion compares two such counts. Labelled as an
            estimate so the numbers aren't read as exact.
          --%>
          {dgettext(
            "dashboard_analytics",
            "Unique visitors and conversion are cookieless estimates: each visitor is counted once per day, so totals over a longer range approximate the number of distinct people. Conversion is the share of visitors who went on to book and is indicative, not exact."
          )}
        </p>

        <VisitsChart.chart
          points={@visits_by_day}
          from={@from}
          to={@to}
          time_zone={@time_zone}
          loading?={!@loaded?}
        />

        <DeviceBreakdown.breakdown devices={@devices} loading?={!@loaded?} />

        <SourcesTable.table sources={@sources} loading?={!@loaded?} />
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
      # Placeholder values for the dead render and the connected mount before
      # `handle_params` loads real data. `loaded?` gates the skeletons so these
      # zeros are never shown as numbers — see the component `loading?` attrs.
      loaded?: false,
      refreshed_at: nil,
      refreshing?: false,
      visits: 0,
      unique_visitors: 0,
      bookings: 0,
      converting_visitors: 0,
      sources: [],
      visits_by_day: [],
      devices: []
    )
  end

  defp assign_window_for(socket, range) do
    days = Map.get(@ranges, range, @ranges[@default_range])
    now = DateTime.utc_now()
    from = DateTime.add(now, -days * 86_400, :second)

    socket
    |> assign(from: from, to: now, time_zone: organizer_time_zone(socket))
    |> assign_collection_notice(from)
  end

  # When the window reaches back before booking analytics began collecting, the
  # earlier days are necessarily empty — explain that rather than letting a
  # freshly launched installation look broken. Driven by the configured launch
  # date (`Analytics.launch_date/0`); absent that, no notice is shown.
  defp assign_collection_notice(socket, from) do
    launch_date = Analytics.launch_date()
    from_date = DateTime.to_date(from)

    partial_window? =
      match?(%Date{}, launch_date) and Date.compare(from_date, launch_date) == :lt

    assign(socket, launch_date: launch_date, partial_window?: partial_window?)
  end

  defp format_launch_date(%Date{} = date) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    day = String.pad_leading(to_string(date.day), 2, "0")
    "#{day} #{LocaleFormat.format_month_name(date.month, locale, :short)} #{date.year}"
  end

  defp format_launch_date(_other), do: ""

  defp organizer_time_zone(socket) do
    case socket.assigns do
      %{profile: %{timezone: tz}} when is_binary(tz) and tz != "" -> tz
      _assigns -> "Etc/UTC"
    end
  end

  defp load_data(
         %{assigns: %{current_user: user, range: range, from: from, to: to, time_zone: time_zone}} =
           socket
       ) do
    # Collapse the ~7 aggregate queries into one cached bundle per
    # {organizer, range}. MetricsCache keys on user.id, so one organizer can
    # never be served another's metrics.
    data =
      MetricsCache.fetch(user.id, range, fn ->
        %{
          visits: Analytics.count_visits(user.id, from, to),
          unique_visitors: Analytics.count_unique_visitors(user.id, from, to),
          bookings: Analytics.count_bookings(user.id, from, to),
          converting_visitors: Analytics.count_converting_visitors(user.id, from, to),
          visits_by_day: Analytics.visits_by_day(user.id, from, to, time_zone),
          sources: Analytics.attribution_table(user.id, from, to),
          devices: Analytics.device_breakdown(user.id, from, to)
        }
      end)

    socket
    |> assign(Map.to_list(data))
    |> assign(:loaded?, true)
    |> assign(:refreshed_at, DateTime.utc_now())
  end

  defp format_refreshed_at(%DateTime{} = dt, time_zone) do
    case DateTime.shift_zone(dt, time_zone || "Etc/UTC") do
      {:ok, local} -> Calendar.strftime(local, "%H:%M:%S")
      {:error, _reason} -> Calendar.strftime(dt, "%H:%M:%S")
    end
  end

  defp format_refreshed_at(_other, _time_zone), do: ""
end
