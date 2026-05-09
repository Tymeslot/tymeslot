defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosedTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.Repo

  describe "handle/1 — won outcomes" do
    test "won dispute on a previously paid booking reverts status to paid" do
      bp =
        insert(:booking_payment,
          status: "disputed",
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_WON"
        )

      event = dispute_closed_event("evt_WON", "ch_WON", "won", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "paid"
    end

    test "won dispute preserves prior partial refunds and reverts to partially_refunded" do
      bp =
        insert(:booking_payment,
          status: "disputed",
          amount_cents: 5000,
          refunded_amount_cents: 1500,
          stripe_charge_id: "ch_WON_PART"
        )

      event = dispute_closed_event("evt_WON_PART", "ch_WON_PART", "won", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "partially_refunded"
      assert reloaded.refunded_amount_cents == 1500
    end
  end

  describe "handle/1 — lost outcomes" do
    test "lost dispute on full charge marks the booking refunded with the disputed amount" do
      bp =
        insert(:booking_payment,
          status: "disputed",
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_LOST"
        )

      event = dispute_closed_event("evt_LOST", "ch_LOST", "lost", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "refunded"
      assert reloaded.refunded_amount_cents == 5000
    end

    test "lost partial dispute marks the booking partially_refunded" do
      bp =
        insert(:booking_payment,
          status: "disputed",
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_LOST_PART"
        )

      event = dispute_closed_event("evt_LOST_PART", "ch_LOST_PART", "lost", 2000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "partially_refunded"
      assert reloaded.refunded_amount_cents == 2000
    end
  end

  describe "handle/1 — bookkeeping" do
    test "is idempotent on event id" do
      bp =
        insert(:booking_payment,
          status: "paid",
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_REPLAY",
          last_event_id: "evt_REPLAY"
        )

      event = dispute_closed_event("evt_REPLAY", "ch_REPLAY", "won", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      # Untouched (last_event_id matched)
      assert reloaded.status == "paid"
    end

    test "ignores warning_closed and other terminal-but-not-decisive statuses" do
      bp =
        insert(:booking_payment,
          status: "disputed",
          amount_cents: 5000,
          stripe_charge_id: "ch_WARNING"
        )

      event = dispute_closed_event("evt_WARNING", "ch_WARNING", "warning_closed", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "disputed"
    end

    test "returns :ok when no booking_payment matches the charge id" do
      event = dispute_closed_event("evt_NOMATCH", "ch_GHOST", "won", 5000)
      assert :ok = ChargeDisputeClosed.handle(event)
    end
  end

  defp dispute_closed_event(event_id, charge_id, dispute_status, amount) do
    %{
      "id" => event_id,
      "type" => "charge.dispute.closed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "dp_#{event_id}",
          "object" => "dispute",
          "charge" => charge_id,
          "amount" => amount,
          "status" => dispute_status
        }
      }
    }
  end
end
