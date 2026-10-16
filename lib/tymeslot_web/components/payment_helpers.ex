defmodule TymeslotWeb.Components.PaymentHelpers do
  @moduledoc """
  Shared formatting helpers for payment amounts and currencies.

  Used by `TymeslotWeb.Dashboard.PaymentsSettingsComponent` and
  `TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal`.
  """

  alias TymeslotWeb.Helpers.LocaleFormat

  # The locales that write the symbol after the amount ("45,00 €").
  @symbol_after_locales ~w(de fr it cs pl uk)

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
  Formats an integer cent amount for a guest reading `locale`: the number
  grouped and separated as `LocaleFormat.format_number/3` does, with the
  symbol before it and no space in English ("€1,234.50") and after it, set
  off by a non-breaking space, in the other locales ("1.234,50 €").

  An unknown locale is formatted as English. Returns an empty string when
  `cents` is not an integer.
  """
  @spec format_amount(integer() | term(), String.t() | term(), String.t()) :: String.t()
  def format_amount(cents, currency, locale) when is_integer(cents) do
    number = LocaleFormat.format_number(cents / 100, locale, 2)
    symbol = currency |> currency_symbol() |> String.trim()

    cond do
      symbol == "" -> number
      locale in @symbol_after_locales -> number <> "\u00A0" <> symbol
      # A letter code such as "CHF" needs a space before the digits, where a
      # sign such as "€" sits flush against them.
      String.match?(symbol, ~r/^\p{L}+$/u) -> symbol <> " " <> number
      true -> symbol <> number
    end
  end

  def format_amount(_cents, _currency, _locale), do: ""

  @doc """
  Returns the display symbol for a currency code.

  Accepts a lowercase ISO 4217 currency code string. Unknown or
  non-string values return an empty string.
  """
  @currency_symbols %{"eur" => "€", "usd" => "$", "gbp" => "£", "chf" => "CHF "}

  @spec currency_symbol(String.t() | term()) :: String.t()
  def currency_symbol(currency) when is_binary(currency) do
    Map.get(@currency_symbols, currency, String.upcase(currency) <> " ")
  end

  def currency_symbol(_currency), do: ""
end
