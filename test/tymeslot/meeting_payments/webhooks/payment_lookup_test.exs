defmodule Tymeslot.MeetingPayments.Webhooks.PaymentLookupTest do
  use Tymeslot.DataCase, async: true

  @moduletag :payments

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  @account "acct_HOST"
  @other_account "acct_ATTACKER"

  defp intent_for_meeting(id, meeting_id) do
    StripeFixtures.object("payment_intent_with_latest_charge", %{
      "id" => id,
      "metadata" => %{"meeting_id" => meeting_id}
    })
  end

  describe "find_for_charge/2" do
    test "matches on the charge id" do
      bp = insert(:booking_payment, stripe_account_id: @account, stripe_charge_id: "ch_MATCH")

      assert PaymentLookup.find_for_charge(charge_event(@account, nil), "ch_MATCH").id == bp.id
    end

    test "falls back to the payment_intent id when the charge id is unlinked" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          stripe_charge_id: nil,
          stripe_payment_intent_id: "pi_MATCH"
        )

      event = charge_event(@account, "pi_MATCH")
      assert PaymentLookup.find_for_charge(event, "ch_UNLINKED").id == bp.id
    end

    test "falls back to meeting_id from PaymentIntent metadata when neither id is linked" do
      meeting = insert(:meeting)

      bp =
        insert(:booking_payment,
          meeting: meeting,
          stripe_account_id: @account,
          stripe_charge_id: nil,
          stripe_payment_intent_id: nil
        )

      StripeStub.expect(:retrieve_payment_intent, intent_for_meeting("pi_RACE", meeting.id))

      assert PaymentLookup.find_for_charge(charge_event(@account, "pi_RACE"), "ch_RACE").id ==
               bp.id

      assert [%{path: "/v1/payment_intents/pi_RACE", headers: headers}] =
               StripeStub.requests(:retrieve_payment_intent)

      assert headers["stripe-account"] == @account
    end

    test "returns nil for a charge that belongs to no Tymeslot booking" do
      StripeStub.expect(
        :retrieve_payment_intent,
        StripeFixtures.object("payment_intent_with_latest_charge", %{
          "id" => "pi_FOREIGN",
          "metadata" => %{}
        })
      )

      assert PaymentLookup.find_for_charge(charge_event(@account, "pi_FOREIGN"), "ch_FOREIGN") ==
               nil

      assert [%{path: "/v1/payment_intents/pi_FOREIGN"}] =
               StripeStub.requests(:retrieve_payment_intent)
    end

    test "returns a transient Stripe failure instead of reading it as no booking" do
      insert(:booking_payment,
        stripe_account_id: @account,
        stripe_charge_id: nil,
        stripe_payment_intent_id: nil
      )

      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "api_error"})

      assert {:error, %StripeError{type: "api_error", status: 500}} =
               PaymentLookup.find_for_charge(charge_event(@account, "pi_BLIP"), "ch_BLIP")
    end

    test "returns nil for an intent Stripe does not know on that account" do
      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "resource_missing"})

      assert PaymentLookup.find_for_charge(charge_event(@account, "pi_UNKNOWN"), "ch_UNKNOWN") ==
               nil
    end

    test "does not call Stripe when no connected account is available" do
      assert PaymentLookup.find_for_charge(charge_event(nil, "pi_NONE"), "ch_NONE") == nil
      assert StripeStub.requests(:retrieve_payment_intent) == []
    end

    test "ignores a row matched by charge id when the event comes from another account" do
      insert(:booking_payment, stripe_account_id: @account, stripe_charge_id: "ch_OWNED")

      assert PaymentLookup.find_for_charge(charge_event(@other_account, nil), "ch_OWNED") == nil
    end

    test "ignores an event that carries no account at all" do
      insert(:booking_payment, stripe_account_id: @account, stripe_charge_id: "ch_NOACCT")

      assert PaymentLookup.find_for_charge(charge_event(nil, nil), "ch_NOACCT") == nil
    end

    # Another connected account can create its own PaymentIntent and stamp a
    # victim's meeting id into its metadata.
    test "ignores a metadata match planted by another connected account" do
      meeting = insert(:meeting)

      insert(:booking_payment,
        meeting: meeting,
        stripe_account_id: @account,
        stripe_charge_id: nil,
        stripe_payment_intent_id: nil
      )

      StripeStub.expect(:retrieve_payment_intent, intent_for_meeting("pi_PLANTED", meeting.id))

      assert PaymentLookup.find_for_charge(
               charge_event(@other_account, "pi_PLANTED"),
               "ch_PLANTED"
             ) == nil

      assert [%{path: "/v1/payment_intents/pi_PLANTED", headers: headers}] =
               StripeStub.requests(:retrieve_payment_intent)

      assert headers["stripe-account"] == @other_account
    end
  end

  describe "find_for_session/1" do
    test "matches on the attached session id" do
      bp =
        insert(:booking_payment, stripe_account_id: @account, stripe_checkout_session_id: "cs_1")

      assert PaymentLookup.find_for_session(session_event(@account, %{"id" => "cs_1"})).id ==
               bp.id
    end

    test "matches on client_reference_id while no session is attached yet" do
      meeting = insert(:meeting)

      bp =
        insert(:booking_payment,
          meeting: meeting,
          stripe_account_id: @account,
          stripe_checkout_session_id: nil
        )

      event = session_event(@account, %{"id" => "cs_NEW", "client_reference_id" => meeting.id})
      assert PaymentLookup.find_for_session(event).id == bp.id
    end

    test "ignores a session from another account that names the booking's meeting" do
      meeting = insert(:meeting)

      insert(:booking_payment,
        meeting: meeting,
        stripe_account_id: @account,
        stripe_checkout_session_id: nil
      )

      event =
        session_event(@other_account, %{"id" => "cs_EVIL", "client_reference_id" => meeting.id})

      assert PaymentLookup.find_for_session(event) == nil
    end

    test "ignores a different session that names a booking with a session attached" do
      meeting = insert(:meeting)

      insert(:booking_payment,
        meeting: meeting,
        stripe_account_id: @account,
        stripe_checkout_session_id: "cs_GENUINE"
      )

      event = session_event(@account, %{"id" => "cs_OTHER", "client_reference_id" => meeting.id})
      assert PaymentLookup.find_for_session(event) == nil
    end
  end

  defp charge_event(account, payment_intent_id) do
    %{
      "id" => "evt_LOOKUP",
      "account" => account,
      "data" => %{"object" => %{"payment_intent" => payment_intent_id}}
    }
  end

  defp session_event(account, object) do
    %{"id" => "evt_LOOKUP", "account" => account, "data" => %{"object" => object}}
  end
end
