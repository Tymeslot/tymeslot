defmodule Tymeslot.MeetingPayments.ApplicationFee do
  @moduledoc """
  Computes the platform application fee in cents from a price and a basis-points
  (bp) configuration.

  * `bp == 0` always returns `0` (free, no platform take).
  * `price_cents == 0` always returns `0`.
  * Any non-zero price at non-zero bp returns at least `1` cent (cent floor),
    and rounds up otherwise so the platform never under-charges itself.
  """

  @doc """
  The fee charged on payments at booking, in basis points (100 bp = 1%), as
  configured by `config :tymeslot, :payment_application_fee_bp` (set from
  `MEETING_PAYMENTS_APPLICATION_FEE_BP` in production). `0` when unset.
  """
  @spec configured_bp() :: non_neg_integer()
  def configured_bp, do: Application.get_env(:tymeslot, :payment_application_fee_bp, 0)

  @spec calculate(price_cents :: non_neg_integer(), bp :: non_neg_integer()) ::
          non_neg_integer()
  def calculate(0, _bp), do: 0
  def calculate(_price_cents, 0), do: 0

  def calculate(price_cents, bp)
      when is_integer(price_cents) and is_integer(bp) and
             price_cents > 0 and bp > 0 do
    max(div(price_cents * bp + 9_999, 10_000), 1)
  end
end
