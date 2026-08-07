defmodule TymeslotWeb.Dashboard.AnalyticsLive.SummaryCards do
  @moduledoc """
  Four-card summary for the analytics dashboard: total visits, unique
  visitors, total bookings, and conversion rate over the chosen window.

  Cards stretch to a shared row height and pin their value to the bottom, so a
  label that wraps to two lines (e.g. "Conversion (est.)") never pushes its
  number out of line with its neighbours. While `loading?` is true each value
  is replaced with a skeleton, so a page load shows a brief shimmer rather than
  a misleading `0` that then jumps to the real figure.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Analytics

  attr :visits, :integer, required: true
  attr :unique_visitors, :integer, required: true
  attr :bookings, :integer, required: true
  attr :converting_visitors, :integer, required: true
  attr :loading?, :boolean, default: false

  @spec cards(map()) :: Phoenix.LiveView.Rendered.t()
  def cards(assigns) do
    assigns =
      assign(
        assigns,
        :conversion_rate,
        Analytics.conversion_rate(assigns.converting_visitors, assigns.unique_visitors)
      )

    ~H"""
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
      <.stat_card
        label={dgettext("dashboard_analytics", "Visits")}
        value={@visits}
        loading?={@loading?}
      />
      <.stat_card
        label={dgettext("dashboard_analytics", "Unique visitors")}
        value={@unique_visitors}
        loading?={@loading?}
      />
      <.stat_card
        label={dgettext("dashboard_analytics", "Bookings")}
        value={@bookings}
        loading?={@loading?}
      />
      <.stat_card
        label={dgettext("dashboard_analytics", "Conversion (est.)")}
        value={"#{@conversion_rate}%"}
        loading?={@loading?}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :loading?, :boolean, default: false

  defp stat_card(assigns) do
    ~H"""
    <div class="card-glass flex h-full flex-col">
      <div class="text-token-sm font-black uppercase tracking-widest text-tymeslot-400">
        {@label}
      </div>
      <div class="mt-auto pt-3">
        <div
          :if={@loading?}
          class="h-9 w-20 animate-pulse rounded-token-md bg-tymeslot-100"
          aria-hidden="true"
        >
        </div>
        <div
          :if={!@loading?}
          class="text-token-3xl font-black tracking-tight tabular-nums text-tymeslot-900"
        >
          {@value}
        </div>
      </div>
    </div>
    """
  end
end
