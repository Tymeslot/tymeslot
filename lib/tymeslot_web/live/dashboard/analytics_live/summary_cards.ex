defmodule TymeslotWeb.Dashboard.AnalyticsLive.SummaryCards do
  @moduledoc """
  Four-card summary for the analytics dashboard: total visits, unique
  visitors, total bookings, and conversion rate over the chosen window.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :visits, :integer, required: true
  attr :unique_visitors, :integer, required: true
  attr :bookings, :integer, required: true

  @spec cards(map()) :: Phoenix.LiveView.Rendered.t()
  def cards(assigns) do
    assigns = assign(assigns, :conversion_rate, conversion_rate(assigns))

    ~H"""
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
      <.stat_card label={gettext("Visits")} value={@visits} />
      <.stat_card label={gettext("Unique visitors")} value={@unique_visitors} />
      <.stat_card label={gettext("Bookings")} value={@bookings} />
      <.stat_card label={gettext("Conversion")} value={"#{@conversion_rate}%"} />
    </div>
    """
  end

  defp conversion_rate(%{visits: 0}), do: "0.0"

  defp conversion_rate(%{visits: visits, bookings: bookings}) do
    :erlang.float_to_binary(bookings / visits * 100, decimals: 1)
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="text-sm font-black uppercase tracking-widest text-tymeslot-400">
        {@label}
      </div>
      <div class="mt-2 text-3xl font-black tracking-tight text-tymeslot-900">
        {@value}
      </div>
    </div>
    """
  end
end
