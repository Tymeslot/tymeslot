defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreatedTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreated
  alias Tymeslot.Repo

  describe "handle/1" do
    test "transitions a paid booking_payment to disputed" do
      bp =
        insert(:booking_payment,
          status: "paid",
          amount_cents: 5000,
          stripe_charge_id: "ch_DISPUTED"
        )

      event = dispute_event("evt_DISPUTE", "ch_DISPUTED")

      assert :ok = ChargeDisputeCreated.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "disputed"
      assert reloaded.last_event_id == "evt_DISPUTE"
    end

    test "preserves refunded_amount_cents on a partially_refunded booking_payment" do
      bp =
        insert(:booking_payment,
          status: "partially_refunded",
          amount_cents: 5000,
          refunded_amount_cents: 1500,
          stripe_charge_id: "ch_PART_DISP"
        )

      event = dispute_event("evt_PART_DISP", "ch_PART_DISP")

      assert :ok = ChargeDisputeCreated.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "disputed"
      assert reloaded.refunded_amount_cents == 1500
    end

    test "is idempotent — replaying the same event id is a no-op" do
      bp =
        insert(:booking_payment,
          status: "disputed",
          amount_cents: 5000,
          stripe_charge_id: "ch_REPLAY_DISP",
          last_event_id: "evt_REPLAY_DISP"
        )

      event = dispute_event("evt_REPLAY_DISP", "ch_REPLAY_DISP")

      assert :ok = ChargeDisputeCreated.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "disputed"
      assert reloaded.last_event_id == "evt_REPLAY_DISP"
    end

    test "returns :ok when no booking_payment matches the charge id" do
      event = dispute_event("evt_NOMATCH", "ch_GHOST")
      assert :ok = ChargeDisputeCreated.handle(event)
    end
  end

  defp dispute_event(event_id, charge_id) do
    %{
      "id" => event_id,
      "type" => "charge.dispute.created",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "dp_#{event_id}",
          "charge" => charge_id,
          "object" => "dispute",
          "amount" => 5000,
          "reason" => "fraudulent"
        }
      }
    }
  end
end
