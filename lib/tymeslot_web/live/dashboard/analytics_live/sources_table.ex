defmodule TymeslotWeb.Dashboard.AnalyticsLive.SourcesTable do
  @moduledoc """
  Renders the per-source attribution table: utm_source, visits, bookings,
  conversion rate. The `sources` list comes from
  `Tymeslot.Analytics.attribution_table/3`.

  Two layouts share one precomputed row set: a column table from the `sm`
  breakpoint up, and stacked cards below it so the four columns don't overflow
  a narrow phone screen. While `loading?` is true a skeleton stands in for both.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Analytics

  attr :sources, :list, required: true
  attr :loading?, :boolean, default: false

  @spec table(map()) :: Phoenix.LiveView.Rendered.t()
  def table(assigns) do
    rows =
      Enum.map(assigns.sources, fn row ->
        %{
          label: row.utm_source || dgettext("dashboard_analytics", "(direct / unknown)"),
          visits: row.visits,
          bookings: row.bookings,
          conversion: Analytics.conversion_rate(row.converting_visitors, row.unique_visitors)
        }
      end)

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div class="card-glass overflow-hidden p-0">
      <div :if={@loading?} class="space-y-3 p-4" aria-hidden="true">
        <div :for={i <- 1..3} class="h-6 w-full animate-pulse rounded-token-md bg-tymeslot-100" id={"src-skeleton-#{i}"}>
        </div>
      </div>

      <%!-- Table layout from the sm breakpoint up --%>
      <table :if={!@loading?} class="hidden w-full text-token-sm sm:table">
        <thead class="bg-tymeslot-50">
          <tr class="text-token-xs font-black uppercase tracking-widest text-tymeslot-400">
            <th class="px-4 py-3 text-left">{dgettext("dashboard_analytics", "Source")}</th>
            <th class="px-4 py-3 text-right">{dgettext("dashboard_analytics", "Visits")}</th>
            <th class="px-4 py-3 text-right">{dgettext("dashboard_analytics", "Bookings")}</th>
            <th class="px-4 py-3 text-right">{dgettext("dashboard_analytics", "Conversion")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class="border-t border-tymeslot-100 text-tymeslot-900">
            <td class="px-4 py-3">{row.label}</td>
            <td class="px-4 py-3 text-right tabular-nums">{row.visits}</td>
            <td class="px-4 py-3 text-right tabular-nums">{row.bookings}</td>
            <td class="px-4 py-3 text-right tabular-nums">{row.conversion}%</td>
          </tr>
          <tr :if={@rows == []}>
            <td colspan="4" class="px-4 py-8 text-center text-tymeslot-400">
              {dgettext("dashboard_analytics", "No traffic in this period yet.")}
            </td>
          </tr>
        </tbody>
      </table>

      <%!-- Stacked cards below the sm breakpoint --%>
      <div :if={!@loading?} class="divide-y divide-tymeslot-100 sm:hidden">
        <div :for={row <- @rows} class="px-4 py-3">
          <div class="font-semibold text-tymeslot-900">{row.label}</div>
          <dl class="mt-2 grid grid-cols-3 gap-2 text-token-xs">
            <div>
              <dt class="text-tymeslot-400">{dgettext("dashboard_analytics", "Visits")}</dt>
              <dd class="tabular-nums font-semibold text-tymeslot-900">{row.visits}</dd>
            </div>
            <div>
              <dt class="text-tymeslot-400">{dgettext("dashboard_analytics", "Bookings")}</dt>
              <dd class="tabular-nums font-semibold text-tymeslot-900">{row.bookings}</dd>
            </div>
            <div>
              <dt class="text-tymeslot-400">{dgettext("dashboard_analytics", "Conversion")}</dt>
              <dd class="tabular-nums font-semibold text-tymeslot-900">{row.conversion}%</dd>
            </div>
          </dl>
        </div>
        <div :if={@rows == []} class="px-4 py-8 text-center text-tymeslot-400">
          {dgettext("dashboard_analytics", "No traffic in this period yet.")}
        </div>
      </div>
    </div>
    """
  end
end
