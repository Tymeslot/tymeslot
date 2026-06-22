defmodule TymeslotWeb.Dashboard.AnalyticsLive.SourcesTable do
  @moduledoc """
  Renders the per-source attribution table: utm_source, visits, bookings,
  conversion rate. The `sources` list comes from
  `Tymeslot.Analytics.attribution_table/3`.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Analytics

  attr :sources, :list, required: true

  @spec table(map()) :: Phoenix.LiveView.Rendered.t()
  def table(assigns) do
    ~H"""
    <div class="card-glass overflow-hidden p-0">
      <table class="w-full text-token-sm">
        <thead class="bg-tymeslot-50">
          <tr class="text-token-xs font-black uppercase tracking-widest text-tymeslot-400">
            <th class="px-4 py-3 text-left">Source</th>
            <th class="px-4 py-3 text-right">Visits</th>
            <th class="px-4 py-3 text-right">Bookings</th>
            <th class="px-4 py-3 text-right">Conversion</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @sources} class="border-t border-tymeslot-100 text-tymeslot-900">
            <td class="px-4 py-3">{row.utm_source || "(direct / unknown)"}</td>
            <td class="px-4 py-3 text-right tabular-nums">{row.visits}</td>
            <td class="px-4 py-3 text-right tabular-nums">{row.bookings}</td>
            <td class="px-4 py-3 text-right tabular-nums">{Analytics.conversion_rate(row.converting_visitors, row.unique_visitors)}%</td>
          </tr>
          <tr :if={@sources == []}>
            <td colspan="4" class="px-4 py-8 text-center text-tymeslot-400">
              No traffic in this period yet.
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
