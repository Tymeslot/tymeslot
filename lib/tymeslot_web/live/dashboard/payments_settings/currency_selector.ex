defmodule TymeslotWeb.Dashboard.PaymentsSettings.CurrencySelector do
  @moduledoc """
  Default-currency tag selector.

  Stateless function component rendered by `PaymentsSettingsComponent`. Renders
  one auto-save tag per allowlisted currency; clicking a tag dispatches
  `change_currency` back to the parent component (`@myself`), which owns the
  persistence. Owns the tag-label formatting (symbol + code).
  """

  use TymeslotWeb, :html

  alias Tymeslot.MeetingPayments

  import TymeslotWeb.Components.PaymentHelpers, only: [currency_symbol: 1]

  attr :account, :map, required: true
  attr :myself, :any, required: true

  @spec currency_selector(map()) :: Phoenix.LiveView.Rendered.t()
  def currency_selector(assigns) do
    assigns = assign(assigns, :currencies, MeetingPayments.currency_allowlist())

    ~H"""
    <.detail_card title="Default currency">
      <p class="text-token-sm text-tymeslot-700 mb-4">
        Changing the currency will reset every paid event type to free —
        existing prices are recorded in the previous currency and would
        otherwise be charged at the new one.
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
    symbol = String.trim(currency_symbol(code))
    upper = String.upcase(code)
    if symbol == upper, do: upper, else: "#{symbol} #{upper}"
  end
end
