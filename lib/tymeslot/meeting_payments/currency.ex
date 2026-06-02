defmodule Tymeslot.MeetingPayments.Currency do
  @moduledoc """
  Currency allowlist and per-currency minimum charge amounts (in cents).
  Stripe requires a per-currency minimum on every charge.
  """

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

  @spec allowed?(String.t()) :: boolean()
  def allowed?(currency), do: Map.has_key?(@minima, currency)

  @spec minimum_cents(String.t()) :: pos_integer()
  def minimum_cents(currency), do: Map.get(@minima, currency, 50)
end
