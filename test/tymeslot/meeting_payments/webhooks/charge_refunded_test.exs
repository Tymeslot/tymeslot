defmodule Tymeslot.MeetingPayments.Webhooks.ChargeRefundedTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Webhooks.ChargeRefunded
  alias Tymeslot.Repo

  describe "handle/1" do
    test "marks booking_payment refunded when full amount has been refunded" do
      bp =
        insert(:booking_payment,
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

  defp refund_event(event_id, charge_id, amount_refunded) do
    %{
      "id" => event_id,
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
