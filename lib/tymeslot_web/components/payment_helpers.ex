defmodule TymeslotWeb.Components.PaymentHelpers do
  @moduledoc """
  Shared formatting helpers for payment amounts and currencies.

  Used by `TymeslotWeb.Dashboard.PaymentsSettingsComponent` and
  `TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal`.
  """

  @doc """
  Formats an integer cent amount with a currency symbol prefix.

  Returns an empty string when `cents` is not an integer.
  """
  @spec format_amount(integer() | term(), String.t() | term()) :: String.t()
  def format_amount(cents, currency) when is_integer(cents) do
    amount = cents / 100
    symbol = currency_symbol(currency)
    "#{symbol}#{:erlang.float_to_binary(amount, decimals: 2)}"
  end

  def format_amount(_cents, _currency), do: ""

  @doc """
  Returns the display symbol for a currency code.

  Accepts a lowercase ISO 4217 currency code string. Unknown or
  non-string values return an empty string.
  """
  @spec currency_symbol(String.t() | term()) :: String.t()
  def currency_symbol("eur"), do: "€"
  def currency_symbol("usd"), do: "$"
  def currency_symbol("gbp"), do: "£"
  def currency_symbol("chf"), do: "CHF "
  def currency_symbol(other) when is_binary(other), do: String.upcase(other) <> " "
  def currency_symbol(_currency), do: ""
end
