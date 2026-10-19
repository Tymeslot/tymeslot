defmodule TymeslotWeb.Dashboard.PaymentsSettings.CurrencySelector do
  @moduledoc """
  Default-currency tag selector.

  Stateless function component rendered by `PaymentsSettingsComponent`. Renders
  one auto-save tag per allowlisted currency; clicking a tag dispatches
  `change_currency` back to the parent component (`@myself`), which owns the
  persistence. Owns the tag-label formatting (symbol + code), and warns when
  the account carries a currency outside the allowlist (an account opened
  before it was enforced): prices cannot be set in it, and unless it counts
  in hundredths it takes no payments either, until one is chosen
  (`MeetingPayments.currency_support/1`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.Money

  attr :account, :map, required: true
  attr :myself, :any, required: true

  @spec currency_selector(map()) :: Phoenix.LiveView.Rendered.t()
  def currency_selector(assigns) do
    assigns =
      assign(assigns,
        currencies: MeetingPayments.currency_allowlist(),
        support: MeetingPayments.currency_support(assigns.account.default_currency)
      )

    ~H"""
    <.detail_card title={dgettext("dashboard_payments", "Default currency")}>
      <.info_box :if={@support == :legacy} variant={:warning} class="mb-4">
        {dgettext(
          "dashboard_payments",
          "Prices can no longer be set in your Stripe account's currency, %{currency}. Bookings are still charged their current prices; choose one of the currencies below to change them.",
          currency: String.upcase(@account.default_currency)
        )}
      </.info_box>
      <.info_box :if={@support == :unsupported} variant={:warning} class="mb-4">
        {dgettext(
          "dashboard_payments",
          "Your Stripe account's currency, %{currency}, is not supported for meeting payments. Choose one of the currencies below to take payments again.",
          currency: String.upcase(@account.default_currency)
        )}
      </.info_box>
      <p class="text-token-sm text-tymeslot-700 mb-4">
        {dgettext(
          "dashboard_payments",
          "Changing the currency will reset every paid event type to free - existing prices are recorded in the previous currency and would otherwise be charged at the new one."
        )}
      </p>
      <div class="flex flex-wrap items-center gap-3">
        <button
          :for={code <- @currencies}
          type="button"
          phx-click="change_currency"
          phx-value-currency={code}
          phx-target={@myself}
          class={[
            "btn-tag-selector btn-tag-selector-primary",
            if(@account.default_currency == code, do: "btn-tag-selector-primary--active")
          ]}
        >
          {currency_tag_label(code)}
        </button>
      </div>
    </.detail_card>
    """
  end

  # Tag label combining the currency symbol and code, e.g. "$ USD" or "€ EUR".
  # Currencies without a distinct glyph (the symbol falls back to the code)
  # show the code alone rather than duplicating it ("CHF", not "CHF CHF").
  defp currency_tag_label(code) do
    symbol = String.trim(Money.symbol(code))
    upper = String.upcase(code)
    if symbol == upper, do: upper, else: "#{symbol} #{upper}"
  end
end
