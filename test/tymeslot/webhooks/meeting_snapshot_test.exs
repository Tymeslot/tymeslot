defmodule Tymeslot.Webhooks.MeetingSnapshotTest do
  use Tymeslot.DataCase, async: true

  @moduletag :webhooks

  import Tymeslot.Factory

  alias Tymeslot.Webhooks.MeetingSnapshot

  describe "snapshot/1" do
    test "captures the event-defining fields as JSON-safe values" do
      meeting =
        insert(:meeting,
          status: :awaiting_approval,
          approval_requested_at: ~U[2026-01-14 09:00:00Z],
          approval_deadline_at: ~U[2026-01-15 09:00:00Z]
        )

      snapshot = MeetingSnapshot.snapshot(meeting)

      assert snapshot["status"] == "awaiting_approval"
      assert snapshot["approval_requested_at"] == "2026-01-14T09:00:00Z"
      assert snapshot["approval_deadline_at"] == "2026-01-15T09:00:00Z"
      assert is_nil(snapshot["decline_reason"])
    end
  end
end
