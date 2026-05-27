defmodule TymeslotWeb.Dashboard.AnalyticsLive.VisitsChart do
  @moduledoc """
  Inline SVG bar chart of daily visits. Kept pure-SVG so it requires no
  JS hook and renders on first paint.

  Accepts a sparse `points` list (days with zero visits may be omitted) and
  fills the gaps using the `from`/`to` date range, so every day in the window
  always gets a bar position — even if that bar has height zero.
  """
  use TymeslotWeb, :html

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

  @spec chart(map()) :: Phoenix.LiveView.Rendered.t()
  def chart(assigns) do
    full_series = build_series(assigns.points, assigns.from, assigns.to)

    assigns =
      assign(assigns,
        series: full_series,
        max: max_visits(full_series),
        width: @width,
        height: @height,
        padding: @padding
      )

    ~H"""
    <div class="card-glass">
      <div class="text-token-xs font-black uppercase tracking-widest text-tymeslot-400">
        Visits over time
      </div>
      <%= if @series == [] do %>
        <div class="mt-4 py-8 text-center text-token-sm text-tymeslot-400">
          No traffic in this period yet.
        </div>
      <% else %>
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          preserveAspectRatio="none"
          class="mt-3 h-48 w-full"
          role="img"
          aria-label="Visits over time"
        >
          <title>Visits over time</title>
          <desc>Bar chart showing daily visit counts for the selected date range.</desc>
          <g :for={{point, idx} <- Enum.with_index(@series)}>
            <rect
              x={bar_x(@width, @padding, length(@series), idx)}
              y={bar_y(@height, @padding, point.visits, @max)}
              width={bar_width(@width, @padding, length(@series))}
              height={bar_height(@height, @padding, point.visits, @max)}
              class="fill-turquoise-500"
            >
              <title>{Date.to_string(point.day)}: {point.visits} {if point.visits == 1, do: "visit", else: "visits"}</title>
            </rect>
          </g>
        </svg>
      <% end %>
    </div>
    """
  end

  # Build a contiguous series covering every day from `from` to `to`,
  # merging in any non-zero visit counts from the sparse `points` list.
  defp build_series(points, from, to) do
    visits_by_day = Map.new(points, fn p -> {p.day, p.visits} end)

    Enum.map(Date.range(from, to), fn day ->
      %{day: day, visits: Map.get(visits_by_day, day, 0)}
    end)
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
