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
      <%!-- With no visitors there is no rate to report, and "0.0%" would read
            as a measured result; a dash says "nothing to measure yet". --%>
      <.stat_card
        label={dgettext("dashboard_analytics", "Conversion (est.)")}
        value={if @unique_visitors > 0, do: "#{@conversion_rate}%", else: "—"}
        value_label={if @unique_visitors == 0, do: dgettext("dashboard_analytics", "No visits yet")}
        loading?={@loading?}
        data-testid="conversion-card"
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :value_label, :string, default: nil, doc: "spoken in place of a placeholder value"
  attr :loading?, :boolean, default: false
  attr :rest, :global

  defp stat_card(assigns) do
    ~H"""
    <div class="card-glass flex h-full flex-col" {@rest}>
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
          <span aria-hidden={@value_label && "true"}>{@value}</span>
          <span :if={@value_label} class="sr-only">{@value_label}</span>
        </div>
      </div>
    </div>
    """
  end
end
