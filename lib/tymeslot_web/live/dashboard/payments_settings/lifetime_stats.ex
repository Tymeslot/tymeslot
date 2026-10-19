defmodule TymeslotWeb.Dashboard.PaymentsSettings.LifetimeStats do
  @moduledoc """
  Lifetime payment totals (received, refunded, platform fee).

  Stateless function component rendered by `PaymentsSettingsComponent`. The
  totals arrive split per currency, since a host who changed their default
  currency holds money in more than one, and each card lists one line per
  currency. With no payments yet, each card shows zero in the account's
  default currency.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  alias Tymeslot.MeetingPayments

  attr :stats, :list, required: true
  attr :account, :map, required: true

  @spec lifetime_stats(map()) :: Phoenix.LiveView.Rendered.t()
  def lifetime_stats(assigns) do
    assigns = assign(assigns, :rows, rows(assigns.stats, assigns.account))

    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
      <.detail_card title={dgettext("dashboard_payments", "Total received")}>
        <.amounts rows={@rows} field={:received} />
      </.detail_card>
      <.detail_card title={dgettext("dashboard_payments", "Refunded")}>
        <.amounts rows={@rows} field={:refunded} />
      </.detail_card>
      <.detail_card title={dgettext("dashboard_payments", "Platform fee paid")}>
        <.amounts rows={@rows} field={:platform_fee} />
      </.detail_card>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :field, :atom, required: true

  defp amounts(assigns) do
    ~H"""
    <p
      :for={row <- @rows}
      class="text-token-2xl font-black text-tymeslot-900"
      data-currency={row.currency}
    >
      {format_amount(Map.fetch!(row, @field), row.currency)}
    </p>
    """
  end

  # Before any payment, zero is shown in the account's currency, supported or
  # not, or in the fallback when the account has none yet.
  defp rows([], account),
    do: [%{currency: zero_currency(account), received: 0, refunded: 0, platform_fee: 0}]

  defp rows(stats, _account), do: stats

  defp zero_currency(%{default_currency: currency}) when is_binary(currency) and currency != "",
    do: currency

  defp zero_currency(_account), do: MeetingPayments.host_currency(nil)
end
