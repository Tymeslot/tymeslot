defmodule TymeslotWeb.Components.PaymentHelpers do
  @moduledoc """
  Template helpers for payment amounts that may be absent.

  Used by `TymeslotWeb.Dashboard.PaymentsSettingsComponent`,
  `TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal` and the
  booking pages' price line.
  """

  alias Tymeslot.MeetingPayments.Money

  @doc """
  Formats an integer cent amount with `Tymeslot.MeetingPayments.Money.format/3`
  in the current locale.

  Returns an empty string when `cents` is not an integer or there is no
  currency, so a template can render a price that is not set yet without a
  guard.
  """
  @spec format_amount(integer() | term(), String.t() | nil) :: String.t()
  def format_amount(cents, currency) when is_integer(cents) and is_binary(currency),
    do: Money.format(cents, currency)

  def format_amount(_cents, _currency), do: ""

  @doc """
  Formats an integer cent amount for a reader of `locale`, as
  `Tymeslot.MeetingPayments.Money.format/3` does ("€1,234.50" in English,
  "1.234,50 €" in German).

  Returns an empty string when `cents` is not an integer or there is no
  currency.
  """
  @spec format_amount(integer() | term(), String.t() | term(), String.t()) :: String.t()
  def format_amount(cents, currency, locale) when is_integer(cents) and is_binary(currency),
    do: Money.format(cents, currency, locale: locale)

  def format_amount(_cents, _currency, _locale), do: ""
end
