defmodule Tymeslot.MeetingPayments.Webhooks.ChargeRefundedTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  # Every booking_payment is charged on this connected account, and every
  # event arrives from it, as Stripe delivers them for a genuine booking.
  @account "acct_TEST_HOST"

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Webhooks.ChargeRefunded
  alias Tymeslot.Repo

  describe "handle/1" do
    test "marks booking_payment refunded when full amount has been refunded" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: "paid",
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_FULL"
        )

      event = refund_event("evt_FULL", "ch_FULL", 5000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "refunded"
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.last_event_id == "evt_FULL"
    end

    test "marks booking_payment partially_refunded when less than full" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: "paid",
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_PART"
        )

      event = refund_event("evt_PART", "ch_PART", 2000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "partially_refunded"
      assert reloaded.refunded_amount_cents == 2000
    end

    test "is idempotent when refunded_amount_cents already matches the event total" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: "refunded",
          amount_cents: 5000,
          refunded_amount_cents: 5000,
          stripe_charge_id: "ch_DUP",
          last_event_id: "evt_PRIOR"
        )

      event = refund_event("evt_DUP", "ch_DUP", 5000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "refunded"
      assert reloaded.refunded_amount_cents == 5000
      # Should still record the most recent event id
      assert reloaded.last_event_id == "evt_DUP"
    end

    test "is a no-op when the same event id has already been processed" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: "partially_refunded",
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
          status: "disputed",
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_DISP"
        )

      event = refund_event("evt_DISP", "ch_DISP", 5000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "disputed"
      assert reloaded.refunded_amount_cents == 5000
    end
  end

  describe "handle/1 with an event from another connected account" do
    test "leaves the booking payment untouched" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: "paid",
          amount_cents: 5000,
          stripe_charge_id: "ch_FOREIGN_REFUND"
        )

      event =
        "evt_FOREIGN_REFUND"
        |> refund_event("ch_FOREIGN_REFUND", 5000)
        |> Map.put("account", "acct_ATTACKER")

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "paid"
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
