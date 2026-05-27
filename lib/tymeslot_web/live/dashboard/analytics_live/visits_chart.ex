defmodule TymeslotWeb.Dashboard.AnalyticsLive.VisitsChart do
  @moduledoc """
  Inline SVG bar chart of daily visits. Kept pure-SVG so it requires no
  JS hook and renders on first paint.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @width 800
  @height 200
  @padding 24

  attr :points, :list, required: true, doc: "list of %{day: Date, visits: integer}"

  @spec chart(map()) :: Phoenix.LiveView.Rendered.t()
  def chart(assigns) do
    assigns =
      assign(assigns,
        max: max_visits(assigns.points),
        width: @width,
        height: @height,
        padding: @padding
      )

    ~H"""
    <div class="card-glass">
      <div class="text-xs font-black uppercase tracking-widest text-tymeslot-400">
        {gettext("Visits over time")}
      </div>
      <%= if @points == [] do %>
        <div class="mt-4 py-8 text-center text-token-sm text-tymeslot-400">
          {gettext("No traffic in this period yet.")}
        </div>
      <% else %>
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          preserveAspectRatio="none"
          class="mt-3 h-48 w-full"
          role="img"
          aria-label={gettext("Visits over time")}
        >
          <g :for={{point, idx} <- Enum.with_index(@points)}>
            <rect
              x={bar_x(@width, @padding, length(@points), idx)}
              y={bar_y(@height, @padding, point.visits, @max)}
              width={bar_width(@width, @padding, length(@points))}
              height={bar_height(@height, @padding, point.visits, @max)}
              class="fill-turquoise-500"
            />
          </g>
        </svg>
      <% end %>
    </div>
    """
  end

  defp max_visits([]), do: 1
  defp max_visits(points), do: max(1, Enum.max_by(points, & &1.visits).visits)

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
