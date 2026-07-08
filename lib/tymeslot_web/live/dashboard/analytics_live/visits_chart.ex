defmodule TymeslotWeb.Dashboard.AnalyticsLive.VisitsChart do
  @moduledoc """
  Inline SVG bar chart of daily visits. Kept pure-SVG so it requires no
  JS hook and renders on first paint.

  Accepts a sparse `points` list (days with zero visits may be omitted) and
  fills the gaps using the `from`/`to` date range, so every day in the window
  always gets a bar position — even if that bar has height zero.

  The bars stretch to fill the card (`preserveAspectRatio="none"`), so all
  human-readable labelling — the legend, the y-axis 0/max range, and the
  start/middle/end dates on the x-axis — is rendered as HTML around the SVG
  rather than as `<text>` inside it (which the non-uniform scaling would
  distort). While `loading?` is true a skeleton is shown instead.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Helpers.LocaleFormat

  @width 800
  @height 200
  @padding 24

  attr :points, :list, required: true, doc: "list of %{day: Date, visits: integer}"

  attr :from, :any,
    required: true,
    doc: "start Date (or DateTime) of the window — used to fill zero-visit days"

  attr :to, :any,
    required: true,
    doc: "end Date (or DateTime) of the window — used to fill zero-visit days"

  attr :time_zone, :string,
    default: "Etc/UTC",
    doc: "organizer time zone — window edges are filled in local days to match the query buckets"

  attr :loading?, :boolean, default: false

  @spec chart(map()) :: Phoenix.LiveView.Rendered.t()
  def chart(assigns) do
    full_series = build_series(assigns.points, assigns.from, assigns.to, assigns.time_zone)

    assigns =
      assign(assigns,
        series: full_series,
        max: max_visits(full_series),
        width: @width,
        height: @height,
        padding: @padding,
        first_label: axis_label(List.first(full_series)),
        mid_label: axis_label(mid_point(full_series)),
        last_label: axis_label(List.last(full_series))
      )

    ~H"""
    <div class="card-glass">
      <div class="flex items-center justify-between gap-2">
        <div class="text-token-xs font-black uppercase tracking-widest text-tymeslot-400">
          {dgettext("dashboard_analytics", "Visits over time")}
        </div>
        <div class="flex items-center gap-1.5 text-token-xs text-tymeslot-500">
          <span class="inline-block h-2.5 w-2.5 rounded-sm bg-turquoise-500" aria-hidden="true"></span>
          {dgettext("dashboard_analytics", "Daily visits")}
        </div>
      </div>

      <div
        :if={@loading?}
        class="mt-4 h-48 w-full animate-pulse rounded-token-lg bg-tymeslot-100"
        aria-hidden="true"
      >
      </div>

      <div
        :if={!@loading? and @series == []}
        class="mt-4 py-8 text-center text-token-sm text-tymeslot-400"
      >
        {dgettext("dashboard_analytics", "No traffic in this period yet.")}
      </div>

      <div :if={!@loading? and @series != []} class="mt-3 flex gap-2">
        <%!-- y-axis: visits range from 0 at the baseline up to the busiest day --%>
        <div
          class="flex h-48 flex-col justify-between py-px text-right text-token-xs tabular-nums text-tymeslot-400"
          aria-hidden="true"
        >
          <span>{@max}</span>
          <span>0</span>
        </div>

        <div class="min-w-0 flex-1">
          <svg
            viewBox={"0 0 #{@width} #{@height}"}
            preserveAspectRatio="none"
            class="h-48 w-full"
            role="img"
            aria-label={dgettext("dashboard_analytics", "Daily visits over the selected date range")}
          >
            <title>{dgettext("dashboard_analytics", "Visits over time")}</title>
            <desc>
              {dgettext(
                "dashboard_analytics",
                "Bar chart showing daily visit counts for the selected date range."
              )}
            </desc>
            <g :for={{point, idx} <- Enum.with_index(@series)}>
              <rect
                x={bar_x(@width, @padding, length(@series), idx)}
                y={bar_y(@height, @padding, point.visits, @max)}
                width={bar_width(@width, @padding, length(@series))}
                height={bar_height(@height, @padding, point.visits, @max)}
                class="fill-turquoise-500"
              >
                <title>
                  {Date.to_string(point.day)}: {dngettext(
                    "dashboard_analytics",
                    "%{count} visit",
                    "%{count} visits",
                    point.visits,
                    count: point.visits
                  )}
                </title>
              </rect>
            </g>
          </svg>

          <%!-- x-axis: first / middle / last day of the window --%>
          <div
            class="mt-2 flex justify-between text-token-xs tabular-nums text-tymeslot-400"
            aria-hidden="true"
          >
            <span>{@first_label}</span>
            <span :if={@mid_label}>{@mid_label}</span>
            <span>{@last_label}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Build a contiguous series covering every day from `from` to `to`,
  # merging in any non-zero visit counts from the sparse `points` list.
  defp build_series(points, from, to, time_zone) do
    visits_by_day = Map.new(points, fn p -> {p.day, p.visits} end)

    Enum.map(Date.range(local_date(from, time_zone), local_date(to, time_zone)), fn day ->
      %{day: day, visits: Map.get(visits_by_day, day, 0)}
    end)
  end

  defp local_date(%DateTime{} = dt, time_zone) do
    case DateTime.shift_zone(dt, time_zone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _reason} -> DateTime.to_date(dt)
    end
  end

  defp local_date(%Date{} = date, _time_zone), do: date

  # A middle tick only earns its place once the range is wide enough that it
  # won't collide with the first/last labels.
  defp mid_point(series) when length(series) >= 5, do: Enum.at(series, div(length(series), 2))
  defp mid_point(_series), do: nil

  defp axis_label(nil), do: nil

  defp axis_label(%{day: day}) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    day_num = String.pad_leading(to_string(day.day), 2, "0")
    "#{day_num} #{LocaleFormat.format_month_name(day.month, locale, :short)}"
  end

  defp max_visits([]), do: 1
  defp max_visits(series), do: max(1, Enum.max_by(series, & &1.visits).visits)

  defp bar_x(width, padding, count, idx) when count > 0 do
    inner = width - 2 * padding
    step = inner / count
    padding + idx * step + step * 0.1
  end

  defp bar_width(width, padding, count) when count > 0 do
    inner = width - 2 * padding
    inner / count * 0.8
  end

  defp bar_y(height, padding, visits, max) do
    inner = height - 2 * padding
    padding + inner - inner * (visits / max)
  end

  defp bar_height(height, padding, visits, max) do
    inner = height - 2 * padding
    inner * (visits / max)
  end
end
