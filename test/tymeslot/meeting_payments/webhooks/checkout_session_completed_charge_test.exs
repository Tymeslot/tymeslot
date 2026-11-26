defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedChargeTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  # Every booking_payment is charged on this connected account, and every
  # event arrives from it, as Stripe delivers them for a genuine booking.
  @account "acct_TEST_HOST"
  @paid_session %{"payment_status" => "paid", "amount_total" => 5000, "currency" => "eur"}

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.BackfillCharge
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  describe "handle/1 recording the charge id" do
    test "backfills stripe_charge_id from an expanded latest_charge" do
      meeting = insert(:meeting, status: :awaiting_payment)

      bp =
        insert_payment(
          meeting: meeting,
          status: :pending,
          stripe_checkout_session_id: "cs_CHARGE"
        )

      # The payment intent is read with `latest_charge` expanded, so the
      # handler must read the charge id from the embedded charge object,
      # otherwise stripe_charge_id stays blank and every downstream
      # refund/dispute lookup (keyed on it) fails.
      StripeStub.expect(
        :retrieve_payment_intent,
        StripeFixtures.object("payment_intent_with_latest_charge", %{
          "id" => "pi_CHARGE",
          "latest_charge" => %{"id" => "ch_REAL"}
        })
      )

      event =
        completed_event("evt_CHARGE", %{
          "id" => "cs_CHARGE",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_CHARGE"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert Repo.reload!(bp).stripe_charge_id == "ch_REAL"

      assert [%{path: "/v1/payment_intents/pi_CHARGE"}] =
               StripeStub.requests(:retrieve_payment_intent)

      refute_enqueued(worker: BackfillCharge)
    end

    test "a failed charge backfill is handed to BackfillCharge and the webhook is acknowledged" do
      meeting = insert(:meeting, status: :awaiting_payment)

      bp =
        insert_payment(
          meeting: meeting,
          status: :pending,
          stripe_checkout_session_id: "cs_BLIP"
        )

      StripeStub.stub(:retrieve_payment_intent, {:transport_error, :timeout})

      event =
        completed_event("evt_BLIP", %{
          "id" => "cs_BLIP",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_BLIP"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :paid
      assert reloaded.stripe_charge_id == nil

      assert_enqueued(
        worker: BackfillCharge,
        args: %{"booking_payment_id" => bp.id, "payment_intent_id" => "pi_BLIP"}
      )
    end

    test "a session naming no payment intent hands nothing to BackfillCharge" do
      meeting = insert(:meeting, status: :awaiting_payment)

      bp =
        insert_payment(
          meeting: meeting,
          status: :pending,
          stripe_checkout_session_id: "cs_NO_PI"
        )

      event =
        completed_event("evt_NO_PI", %{"id" => "cs_NO_PI", "client_reference_id" => meeting.id})

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert Repo.reload!(bp).status == :paid
      assert StripeStub.requests(:retrieve_payment_intent) == []
      refute_enqueued(worker: BackfillCharge)
    end
  end

  defp insert_payment(attrs),
    do: insert(:booking_payment, Keyword.put_new(attrs, :stripe_account_id, @account))

  defp completed_event(event_id, object) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{"object" => Map.merge(@paid_session, object)}
    }
  end
end
