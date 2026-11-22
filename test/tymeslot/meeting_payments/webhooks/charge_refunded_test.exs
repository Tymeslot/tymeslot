defmodule Tymeslot.MeetingPayments.Webhooks.ChargeRefundedTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  # Every booking_payment is charged on this connected account, and every
  # event arrives from it, as Stripe delivers them for a genuine booking.
  @account "acct_TEST_HOST"

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.MeetingPayments.Webhooks.ChargeRefunded
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  describe "handle/1" do
    test "marks booking_payment refunded when full amount has been refunded" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_FULL"
        )

      event = refund_event("evt_FULL", "ch_FULL", 5000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.last_event_id == "evt_FULL"
    end

    test "marks booking_payment partially_refunded when less than full" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_PART"
        )

      event = refund_event("evt_PART", "ch_PART", 2000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :partially_refunded
      assert reloaded.refunded_amount_cents == 2000
    end

    test "is idempotent when refunded_amount_cents already matches the event total" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :refunded,
          amount_cents: 5000,
          refunded_amount_cents: 5000,
          stripe_charge_id: "ch_DUP",
          last_event_id: "evt_PRIOR"
        )

      event = refund_event("evt_DUP", "ch_DUP", 5000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
      # Should still record the most recent event id
      assert reloaded.last_event_id == "evt_DUP"
    end

    test "is a no-op when the same event id has already been processed" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :partially_refunded,
          amount_cents: 5000,
          refunded_amount_cents: 2000,
          stripe_charge_id: "ch_SAME",
          last_event_id: "evt_SAME"
        )

      event = refund_event("evt_SAME", "ch_SAME", 3500)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      # Untouched because last_event_id matched
      assert reloaded.refunded_amount_cents == 2000
    end

    test "returns :ok when no booking_payment matches the charge id" do
      event = refund_event("evt_NOMATCH", "ch_GHOST", 1000)
      assert :ok = ChargeRefunded.handle(event)
    end

    test "preserves status disputed when reconciling refund alongside a dispute" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_DISP"
        )

      event = refund_event("evt_DISP", "ch_DISP", 5000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.refunded_amount_cents == 5000
    end
  end

  describe "handle/1 after a partly lost dispute" do
    # Stripe's `amount_refunded` counts refunds only; the 3000 a lost
    # dispute took is no part of it.
    test "records a refund of the remainder and settles the payment" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :partially_refunded,
          amount_cents: 5000,
          refunded_amount_cents: 3000,
          disputed_lost_cents: 3000,
          stripe_charge_id: "ch_AFTER_LOSS"
        )

      assert :ok = ChargeRefunded.handle(refund_event("evt_AFTER_LOSS", "ch_AFTER_LOSS", 2000))

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.disputed_lost_cents == 3000
    end

    test "records a smaller refund on top of the loss" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :partially_refunded,
          amount_cents: 5000,
          refunded_amount_cents: 3000,
          disputed_lost_cents: 3000,
          stripe_charge_id: "ch_PART_AFTER_LOSS"
        )

      assert :ok =
               ChargeRefunded.handle(
                 refund_event("evt_PART_AFTER_LOSS", "ch_PART_AFTER_LOSS", 500)
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :partially_refunded
      assert reloaded.refunded_amount_cents == 3500
    end
  end

  # A refund that races ahead of checkout.session.completed finds the row
  # only through the payment intent's metadata, read from Stripe.
  describe "handle/1 when the row is found only through Stripe" do
    setup do
      meeting = insert(:meeting)

      bp =
        insert(:booking_payment,
          meeting: meeting,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: nil,
          stripe_payment_intent_id: nil
        )

      event =
        put_in(
          refund_event("evt_BLIP", "ch_x", 5000),
          ["data", "object", "payment_intent"],
          "pi_x"
        )

      %{bp: bp, meeting: meeting, event: event}
    end

    test "a transient intent lookup makes charge.refunded answer retry_later", %{
      bp: bp,
      event: event
    } do
      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "api_error"})

      assert {:error, :retry_later, %StripeError{type: "api_error"}} =
               ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.refunded_amount_cents == 0
      assert reloaded.status == :paid
      assert reloaded.last_event_id == nil
    end

    test "a redelivery after the blip succeeds", %{bp: bp, meeting: meeting, event: event} do
      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "api_error"})
      assert {:error, :retry_later, _reason} = ChargeRefunded.handle(event)

      StripeStub.stub(
        :retrieve_payment_intent,
        StripeFixtures.object("payment_intent_with_latest_charge", %{
          "id" => "pi_x",
          "metadata" => %{"meeting_id" => meeting.id}
        })
      )

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.status == :refunded
    end

    test "an intent Stripe does not know is still acknowledged", %{bp: bp, event: event} do
      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "resource_missing"})

      assert :ok = ChargeRefunded.handle(event)
      assert Repo.reload!(bp).refunded_amount_cents == 0
    end

    # A redelivery would be refused the same way for as long as Stripe keeps
    # trying, so the event is acknowledged and an admin told it went unrecorded.
    test "a refused intent lookup is acknowledged with one admin alert", %{bp: bp, event: event} do
      capture_admin_alerts()

      StripeStub.stub(
        :retrieve_payment_intent,
        {403,
         %{
           "error" => %{
             "type" => "invalid_request_error",
             "message" => "The provided key does not have access to account acct_TEST_HOST."
           }
         }}
      )

      assert :ok = ChargeRefunded.handle(event)
      assert Repo.reload!(bp).refunded_amount_cents == 0

      assert_received {:send_alert, :connect_event_unmatched, alert}

      assert %{
               event_id: "evt_BLIP",
               charge_id: "ch_x",
               payment_intent_id: "pi_x",
               stripe_account_id: @account
             } = alert

      refute_received {:send_alert, _type, _alert}
    end
  end

  describe "handle/1 with an event from another connected account" do
    test "leaves the booking payment untouched" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          stripe_charge_id: "ch_FOREIGN_REFUND"
        )

      event =
        "evt_FOREIGN_REFUND"
        |> refund_event("ch_FOREIGN_REFUND", 5000)
        |> Map.put("account", "acct_ATTACKER")

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :paid
      assert reloaded.refunded_amount_cents == 0
      assert reloaded.last_event_id == nil
    end
  end

  defp refund_event(event_id, charge_id, amount_refunded) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "charge.refunded",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => charge_id,
          "amount_refunded" => amount_refunded,
          "object" => "charge"
        }
      }
    }
  end
end
