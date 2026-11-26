defmodule Tymeslot.StripeStubResponses do
  @moduledoc """
  Answers for `Tymeslot.StripeStub` that depend on the request, in the shape
  Stripe gives a request made as production makes it.
  """

  alias Tymeslot.StripeFixtures

  @doc """
  The answer to a `create_refund` request. `Refunds` always asks for the
  charge expanded, so Stripe returns `charge` as an object whose
  `amount_refunded` counts this refund on top of `prior` cents refunded
  before. The refund's `amount` is the one the request asked for.

  Given an ID alone (and optionally `prior`), returns a response function
  answering each request that way, for a stub that needs no assertion on the
  request.
  """
  @spec refund(String.t()) :: (Tymeslot.StripeStub.request() -> map())
  def refund(id) when is_binary(id), do: refund(id, 0)

  @spec refund(String.t(), non_neg_integer()) :: (Tymeslot.StripeStub.request() -> map())
  @spec refund(Tymeslot.StripeStub.request(), String.t()) :: map()
  def refund(id, prior) when is_binary(id) and is_integer(prior), do: &refund(&1, id, prior)
  def refund(%{} = request, id) when is_binary(id), do: refund(request, id, 0)

  @spec refund(Tymeslot.StripeStub.request(), String.t(), non_neg_integer()) :: map()
  def refund(%{form: %{"amount" => amount}}, id, prior) do
    amount = String.to_integer(amount)

    StripeFixtures.object("refund_with_charge", %{
      "id" => id,
      "amount" => amount,
      "charge" => %{"amount_refunded" => prior + amount}
    })
  end

  @doc """
  The answer to a `retrieve_payment_intent` request for `payment_intent_id`
  whose latest charge is `charge_id`, expanded as `ChargeBackfill` asks for.
  """
  @spec payment_intent(String.t(), String.t()) :: map()
  def payment_intent(payment_intent_id, charge_id) do
    StripeFixtures.object("payment_intent_with_latest_charge", %{
      "id" => payment_intent_id,
      "latest_charge" => %{"id" => charge_id}
    })
  end

  @doc "A created Checkout Session `id` whose hosted page is at `url`."
  @spec checkout_session(String.t(), String.t()) :: map()
  def checkout_session(id, url) do
    StripeFixtures.object("checkout_session_payment", %{"id" => id, "url" => url})
  end
end
