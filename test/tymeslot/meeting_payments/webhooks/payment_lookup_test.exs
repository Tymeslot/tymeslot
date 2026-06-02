defmodule Tymeslot.MeetingPayments.Webhooks.PaymentLookupTest do
  use Tymeslot.DataCase, async: true

  @moduletag :payments

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup

  setup :verify_on_exit!

  describe "find/3" do
    test "matches on the charge id" do
      bp = insert(:booking_payment, stripe_charge_id: "ch_MATCH")

      assert PaymentLookup.find("ch_MATCH", nil, nil).id == bp.id
    end

    test "falls back to the payment_intent id when the charge id is unlinked" do
      bp = insert(:booking_payment, stripe_charge_id: nil, stripe_payment_intent_id: "pi_MATCH")

      assert PaymentLookup.find("ch_UNLINKED", "pi_MATCH", nil).id == bp.id
    end

    test "falls back to meeting_id from PaymentIntent metadata when neither id is linked" do
      meeting = insert(:meeting)

      bp =
        insert(:booking_payment,
          meeting: meeting,
          stripe_charge_id: nil,
          stripe_payment_intent_id: nil
        )

      expect(StripeAdapterMock, :retrieve_payment_intent, fn "pi_RACE", opts ->
        assert opts[:connect_account] == "acct_HOST"
        {:ok, %{metadata: %{"meeting_id" => meeting.id}}}
      end)

      assert PaymentLookup.find("ch_RACE", "pi_RACE", "acct_HOST").id == bp.id
    end

    test "returns nil for a charge that belongs to no Tymeslot booking" do
      expect(StripeAdapterMock, :retrieve_payment_intent, fn "pi_FOREIGN", _opts ->
        {:ok, %{metadata: %{}}}
      end)

      assert PaymentLookup.find("ch_FOREIGN", "pi_FOREIGN", "acct_HOST") == nil
    end

    test "does not call Stripe when no connected account is available" do
      # No `expect` is set, so a retrieve_payment_intent call would be unexpected.
      assert PaymentLookup.find("ch_NONE", "pi_NONE", nil) == nil
    end
  end
end
