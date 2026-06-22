defmodule TymeslotWeb.Dashboard.AnalyticsLive.SummaryCards do
  @moduledoc """
  Four-card summary for the analytics dashboard: total visits, unique
  visitors, total bookings, and conversion rate over the chosen window.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Analytics

  attr :visits, :integer, required: true
  attr :unique_visitors, :integer, required: true
  attr :bookings, :integer, required: true
  attr :converting_visitors, :integer, required: true

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
      <.stat_card label="Visits" value={@visits} />
      <.stat_card label="Unique visitors" value={@unique_visitors} />
      <.stat_card label="Bookings" value={@bookings} />
      <.stat_card label="Conversion (est.)" value={"#{@conversion_rate}%"} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="text-token-sm font-black uppercase tracking-widest text-tymeslot-400">
        {@label}
      </div>
      <div class="mt-2 text-token-3xl font-black tracking-tight text-tymeslot-900">
        {@value}
      </div>
    </div>
    """
  end
end
