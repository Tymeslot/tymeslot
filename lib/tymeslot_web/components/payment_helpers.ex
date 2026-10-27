defmodule TymeslotWeb.Components.PaymentHelpers do
  @moduledoc """
  Template helpers for payment amounts that may be absent.

  Used by `TymeslotWeb.Dashboard.PaymentsSettingsComponent`,
  `TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal` and the
  booking pages' price line.
  """

  alias Tymeslot.MeetingPayments.Money
  alias TymeslotWeb.Helpers.LocaleFormat

  # The locales that write the symbol after the amount ("45,00 €").
  @symbol_after_locales ~w(de fr it cs pl uk)

  @doc """
  Formats an integer cent amount with `Tymeslot.MeetingPayments.Money.format/3`.

  Returns an empty string when `cents` is not an integer or there is no
  currency, so a template can render a price that is not set yet without a
  guard.
  """
  @spec format_amount(integer() | term(), String.t() | nil) :: String.t()
  def format_amount(cents, currency) when is_integer(cents) and is_binary(currency),
    do: Money.format(cents, currency)

  def format_amount(_cents, _currency), do: ""

  @doc """
  Formats an integer cent amount for a guest reading `locale`: the number
  grouped and separated as `LocaleFormat.format_number/3` does, in the
  currency's minor units (`Money.minor_units/1`), with the symbol before it
  and no space in English ("€1,234.50") and after it, set off by a
  non-breaking space, in the other locales ("1.234,50 €").

  An unknown locale is formatted as English. Returns an empty string when
  `cents` is not an integer or there is no currency.
  """
  @spec format_amount(integer() | term(), String.t() | term(), String.t()) :: String.t()
  def format_amount(cents, currency, locale) when is_integer(cents) and is_binary(currency) do
    units = Money.minor_units(currency)
    number = LocaleFormat.format_number(cents / Integer.pow(10, units), locale, units)
    symbol = currency |> Money.symbol() |> String.trim()

    cond do
      locale in @symbol_after_locales -> number <> " " <> symbol
      # A letter code such as "CHF" needs a space before the digits, where a
      # sign such as "€" sits flush against them.
      String.match?(symbol, ~r/^\p{L}+$/u) -> symbol <> " " <> number
      true -> symbol <> number
    end
  end

  def format_amount(_cents, _currency, _locale), do: ""
end
