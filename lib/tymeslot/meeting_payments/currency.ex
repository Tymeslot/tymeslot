defmodule Tymeslot.MeetingPayments.Currency do
  @moduledoc """
  Currency allowlist and per-currency minimum charge amounts (in cents).
  Stripe requires a per-currency minimum on every charge.
  """

  alias Tymeslot.MeetingPayments.Money

  # The pricing currency assumed for a host with no live Connect account, or
  # one whose account carries no default currency yet.
  @fallback "eur"

  @minima %{
    "eur" => 50,
    "usd" => 50,
    "gbp" => 30,
    "chf" => 50,
    "sek" => 300,
    "nok" => 300,
    "dkk" => 250,
    "pln" => 200,
    "czk" => 1500,
    "huf" => 17_500,
    "cad" => 50,
    "aud" => 50,
    "nzd" => 50
  }

  @spec allowlist() :: [String.t()]
  def allowlist, do: Map.keys(@minima)

  @doc "The pricing currency used when a host has no account currency to go by."
  @spec fallback() :: String.t()
  def fallback, do: @fallback

  @spec allowed?(String.t() | nil) :: boolean()
  def allowed?(currency), do: Map.has_key?(@minima, currency)

  @doc """
  How far meeting payments support an account in `currency`:

    * `:supported` - an allowlisted currency;
    * `:legacy` - outside the allowlist (an account opened before it was
      enforced) but counted in hundredths, as every stored price is, so
      checkout still charges its stored prices, while setting a new price
      waits for a supported currency;
    * `:unsupported` - outside the allowlist and counted in whole units or
      thousandths, where a stored price would be charged at the wrong scale
      (a hundred times over in whole units), so it takes no payments at all;
    * `:none` - no currency yet.
  """
  @spec support(String.t() | nil) :: :supported | :legacy | :unsupported | :none
  def support(currency) when is_binary(currency) and currency != "" do
    cond do
      allowed?(currency) -> :supported
      Money.minor_units(currency) == 2 -> :legacy
      true -> :unsupported
    end
  end

  def support(_currency), do: :none

  @doc "Whether checkout can charge an account in `currency` (see `support/1`)."
  @spec chargeable?(String.t() | nil) :: boolean()
  def chargeable?(currency), do: support(currency) in [:supported, :legacy]

  @doc """
  The smallest amount Stripe charges in `currency`, in minor units.

  Only defined for an allowlisted currency: a host's currency is validated
  where it is stored, so an unknown code here is a bug, and raises rather
  than answering with a minimum that belongs to another currency.
  """
  @spec minimum_cents(String.t()) :: pos_integer()
  def minimum_cents(currency) when is_map_key(@minima, currency),
    do: Map.fetch!(@minima, currency)
end
