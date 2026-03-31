defmodule Tymeslot.Integrations.Calendar.SyncTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :unit

  import Mox

  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  describe "reconcile/4 with :deleted signal" do
    test "sets calendar_sync_status to 'externally_deleted' and auto-cancels the meeting" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-abc-123"
        )

      assert :ok = Sync.reconcile(integration.id, "evt-abc-123", nil, :deleted)

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_deleted"
      assert updated.status == "cancelled"
      assert updated.cancelled_at != nil
      assert updated.cancellation_reason == "Cancelled externally via calendar sync"
    end

    test "does not cancel an already cancelled meeting" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-cancelled-1",
          status: "cancelled",
          cancelled_at: DateTime.utc_now(:second)
        )

      assert :ok = Sync.reconcile(integration.id, "evt-cancelled-1", nil, :deleted)

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_deleted"
      # Status remains cancelled, no double-cancel
      assert updated.status == "cancelled"
      assert updated.cancelled_at == meeting.cancelled_at
    end

    test "does not cancel a completed meeting" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-completed-1",
          status: "completed"
        )

      assert :ok = Sync.reconcile(integration.id, "evt-completed-1", nil, :deleted)

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_deleted"
      # Status remains completed
      assert updated.status == "completed"
    end
  end

  describe "reconcile/4 with :modified signal" do
    test "sets calendar_sync_status to 'externally_modified' without cancelling" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-xyz-456"
        )

      assert :ok = Sync.reconcile(integration.id, "evt-xyz-456", nil, :modified)

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_modified"
      # Meeting status unchanged — :modified does not cancel
      assert updated.status == meeting.status
    end
  end

  describe "reconcile/4 idempotency" do
    test "does not write to the DB when status already matches the incoming signal" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-idem-789",
          calendar_sync_status: "externally_deleted"
        )

      assert :ok = Sync.reconcile(integration.id, "evt-idem-789", nil, :deleted)

      {:ok, after_second_call} = MeetingQueries.get_meeting(meeting.id)

      # Status unchanged
      assert after_second_call.calendar_sync_status == "externally_deleted"

      # updated_at should not have advanced (no DB write occurred)
      assert after_second_call.updated_at == meeting.updated_at
    end
  end

  describe "reconcile/4 UID fallback" do
    test "finds meeting by uid when provider_event_id is nil" do
      integration = insert(:calendar_integration)
      uid = "caldav-uid-#{System.unique_integer([:positive])}"

      meeting =
        insert(:meeting,
          uid: uid,
          calendar_integration_id: integration.id,
          provider_event_id: nil
        )

      assert :ok = Sync.reconcile(integration.id, nil, uid, :deleted)

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_deleted"
    end
  end

  describe "reconcile/4 not-found behaviour" do
    test "returns :ok without error when no meeting matches the provider_event_id" do
      integration = insert(:calendar_integration)

      assert :ok = Sync.reconcile(integration.id, "no-such-event-id", nil, :deleted)
    end

    test "returns :ok without error when no meeting matches the uid" do
      integration = insert(:calendar_integration)

      assert :ok = Sync.reconcile(integration.id, nil, "no-such-uid", :deleted)
    end

    test "returns :ok without error when both provider_event_id and uid are nil" do
      integration = insert(:calendar_integration)

      assert :ok = Sync.reconcile(integration.id, nil, nil, :deleted)
    end
  end
end
