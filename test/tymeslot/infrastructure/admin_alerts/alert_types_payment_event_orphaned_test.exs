defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypesPaymentEventOrphanedTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :payments
  @moduletag :unit

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

  @orphan %{
    event_type: "trial_will_end",
    event_id: "evt_1",
    referent_id: "sub_1",
    job_id: 42,
    reason_code: :subscription_not_found,
    reason_message: "subscription_not_found",
    summary: "Payment event referent never appeared after 5 snoozes"
  }

  test "is registered as a payment error" do
    assert AlertTypes.get(:payment_event_orphaned) == %{category: "Payment", severity: :error}
  end

  test "the message names the event type, event id, referent and reason" do
    message = AlertTypes.format_message(:payment_event_orphaned, @orphan)

    assert message ==
             "Payment event trial_will_end (ID: evt_1, referent: sub_1) discarded: " <>
               "Payment event referent never appeared after 5 snoozes (subscription_not_found)"
  end

  test "an event without a Stripe event id is named by its referent" do
    message =
      AlertTypes.format_message(:payment_event_orphaned, Map.delete(@orphan, :event_id))

    assert message =~ "Payment event trial_will_end (ID: unknown, referent: sub_1)"
  end

  test "orphans of two different events do not share a dedup key" do
    refute AlertTypes.dedup_key(:payment_event_orphaned, @orphan) ==
             AlertTypes.dedup_key(:payment_event_orphaned, %{@orphan | event_id: "evt_2"})
  end

  test "orphans of two event types with the same id do not share a dedup key" do
    refute AlertTypes.dedup_key(:payment_event_orphaned, @orphan) ==
             AlertTypes.dedup_key(:payment_event_orphaned, %{
               @orphan
               | event_type: "dispute_closed"
             })
  end

  test "the dedup key falls back to the referent, then the job, without an event id" do
    no_event_id = Map.delete(@orphan, :event_id)

    refute AlertTypes.dedup_key(:payment_event_orphaned, no_event_id) ==
             AlertTypes.dedup_key(:payment_event_orphaned, %{no_event_id | referent_id: "sub_2"})

    no_ids = Map.delete(no_event_id, :referent_id)

    refute AlertTypes.dedup_key(:payment_event_orphaned, no_ids) ==
             AlertTypes.dedup_key(:payment_event_orphaned, %{no_ids | job_id: 43})
  end

  test "a retry of the same orphaned event keeps its dedup key" do
    assert AlertTypes.dedup_key(:payment_event_orphaned, @orphan) ==
             AlertTypes.dedup_key(:payment_event_orphaned, %{@orphan | job_id: 99})
  end
end
