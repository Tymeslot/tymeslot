defmodule TymeslotWeb.Dashboard.PaymentsSettings.LifetimeStats do
  @moduledoc """
  Lifetime payment totals (received, refunded, platform fee).

  Stateless function component rendered by `PaymentsSettingsComponent`. Only
  rendered when the connect account is non-nil, so `account.default_currency`
  is always available for formatting.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :stats, :map, required: true
  attr :account, :map, required: true

  @spec lifetime_stats(map()) :: Phoenix.LiveView.Rendered.t()
  def lifetime_stats(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
      <.detail_card title={dgettext("dashboard_payments", "Total received")}>
        <p class="text-token-2xl font-black text-tymeslot-900">
          {format_amount(@stats.received, @account.default_currency)}
        </p>
      </.detail_card>
      <.detail_card title={dgettext("dashboard_payments", "Refunded")}>
        <p class="text-token-2xl font-black text-tymeslot-900">
          {format_amount(@stats.refunded, @account.default_currency)}
        </p>
      </.detail_card>
      <.detail_card title={dgettext("dashboard_payments", "Platform fee paid")}>
        <p class="text-token-2xl font-black text-tymeslot-900">
          {format_amount(@stats.platform_fee, @account.default_currency)}
        </p>
      </.detail_card>
    </div>
    """
  end
end
