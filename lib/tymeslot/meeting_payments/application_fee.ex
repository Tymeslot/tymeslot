defmodule Tymeslot.MeetingPayments.ApplicationFee do
  @moduledoc """
  Computes the platform application fee in cents from a price and a basis-points
  (bp) configuration.

  * `bp == 0` always returns `0` (free, no platform take).
  * `price_cents == 0` always returns `0`.
  * Any non-zero price at non-zero bp returns at least `1` cent (cent floor),
    and rounds up otherwise so the platform never under-charges itself.
  """

  @spec calculate(price_cents :: non_neg_integer(), bp :: non_neg_integer()) ::
          non_neg_integer()
  def calculate(0, _bp), do: 0
  def calculate(_price_cents, 0), do: 0

  def calculate(price_cents, bp)
      when is_integer(price_cents) and is_integer(bp) and
             price_cents > 0 and bp > 0 do
    raw = price_cents * bp / 10_000
    ceil = trunc(:math.ceil(raw))
    max(ceil, 1)
  end
end
