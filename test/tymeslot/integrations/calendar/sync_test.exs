defmodule Tymeslot.Integrations.Calendar.SyncTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations
  @moduletag :unit

  import Mox

  alias Ecto.UUID
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

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
      assert %DateTime{} = updated.cancelled_at
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
      # A cancelled meeting's slot is void: we deleted its provider event
      # ourselves, so the absence is expected and must not be mislabelled.
      assert updated.calendar_sync_status == nil
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
      # A completed meeting is no longer interactive, so it never expects a
      # provider event either: nothing is left to flag or act on.
      assert updated.calendar_sync_status == nil
      # Status remains completed
      assert updated.status == "completed"
    end

    test "does not cancel a confirmed meeting with a pending reschedule request, and does not mislabel its sync status" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-resched-pending-1",
          status: "confirmed",
          reschedule_requested_at: DateTime.utc_now(:second)
        )

      assert :ok = Sync.reconcile(integration.id, "evt-resched-pending-1", nil, :deleted)

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      # We deleted the provider event ourselves when the reschedule was
      # requested — its absence is expected, not an external deletion.
      assert updated.calendar_sync_status == nil
      assert updated.status == "confirmed"
      assert updated.cancelled_at == nil

      assert all_enqueued(worker: EmailWorker) == []
    end

    test "does not cancel a meeting with the legacy reschedule_requested status" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-resched-legacy-1",
          status: "reschedule_requested"
        )

      assert :ok = Sync.reconcile(integration.id, "evt-resched-legacy-1", nil, :deleted)

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == nil
      assert updated.status == "reschedule_requested"
      assert updated.cancelled_at == nil

      assert all_enqueued(worker: EmailWorker) == []
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

    test "does not mislabel a meeting with a pending reschedule request as externally modified" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-resched-pending-modified-1",
          status: "confirmed",
          reschedule_requested_at: DateTime.utc_now(:second)
        )

      assert :ok =
               Sync.reconcile(integration.id, "evt-resched-pending-modified-1", nil, :modified)

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      # We deleted the provider event ourselves when the reschedule was
      # requested — a lingering async edit signal for it must not be
      # mislabelled as an external modification of a live event.
      assert updated.calendar_sync_status == nil
      assert updated.status == "confirmed"
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

    test "does not send duplicate email when :modified signal arrives twice" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-dup-email-1",
          calendar_sync_status: nil
        )

      # First call: sets status and sends notification
      assert :ok = Sync.reconcile(integration.id, "evt-dup-email-1", nil, :modified)

      {:ok, after_first} = MeetingQueries.get_meeting(meeting.id)
      assert after_first.calendar_sync_status == "externally_modified"
      first_updated_at = after_first.updated_at

      # Second call: status already matches, should be a no-op
      assert :ok = Sync.reconcile(integration.id, "evt-dup-email-1", nil, :modified)

      {:ok, after_second} = MeetingQueries.get_meeting(meeting.id)
      assert after_second.calendar_sync_status == "externally_modified"
      # updated_at should NOT have changed — no DB write, no email
      assert after_second.updated_at == first_updated_at
    end

    test "does not re-cancel when :deleted signal arrives twice" do
      integration = insert(:calendar_integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-dup-cancel-1",
          calendar_sync_status: nil
        )

      # First call: sets status and cancels
      assert :ok = Sync.reconcile(integration.id, "evt-dup-cancel-1", nil, :deleted)

      {:ok, after_first} = MeetingQueries.get_meeting(meeting.id)
      assert after_first.calendar_sync_status == "externally_deleted"
      assert after_first.status == "cancelled"
      first_updated_at = after_first.updated_at

      # Second call: already deleted, should be a no-op
      assert :ok = Sync.reconcile(integration.id, "evt-dup-cancel-1", nil, :deleted)

      {:ok, after_second} = MeetingQueries.get_meeting(meeting.id)
      assert after_second.updated_at == first_updated_at
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

    test "falls back to uid when the provider_event_id is present but matches nothing" do
      integration = insert(:calendar_integration)
      uid = "caldav-uid-#{System.unique_integer([:positive])}"

      meeting =
        insert(:meeting,
          uid: uid,
          calendar_integration_id: integration.id,
          provider_event_id: nil
        )

      # A CalDAV cache row offers its href as the provider event id. No
      # meeting carries that href, so the lookup must fall back to the UID
      # rather than giving up on the first miss.
      assert :ok = Sync.reconcile(integration.id, "/cal/primary/#{uid}.ics", uid, :deleted)

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

  describe "persist_normalised_events/2" do
    defp build_timed_event(integration, provider_event_id) do
      now = DateTime.utc_now(:microsecond)

      CalendarEvent.new!(%{
        uid: "persist-uid-#{System.unique_integer([:positive])}",
        calendar_integration_id: integration.id,
        provider: :caldav,
        provider_calendar_id: "/cal/primary",
        provider_event_id: provider_event_id,
        all_day: false,
        start_at: now,
        end_at: DateTime.add(now, 3600, :second),
        synced_at: now
      })
    end

    defp build_all_day_event(integration, provider_event_id, start_date) do
      CalendarEvent.new!(%{
        uid: "persist-allday-uid-#{System.unique_integer([:positive])}",
        calendar_integration_id: integration.id,
        provider: :caldav,
        provider_calendar_id: "/cal/primary",
        provider_event_id: provider_event_id,
        all_day: true,
        start_date: start_date,
        end_date: Date.add(start_date, 1),
        synced_at: DateTime.utc_now(:microsecond)
      })
    end

    test "happy path: upserts events and broadcasts PubSub message" do
      integration = insert(:calendar_integration)
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{integration.user_id}")

      event = build_timed_event(integration, "evt-persist-1")

      assert :ok = Sync.persist_normalised_events(integration, [event])

      assert_receive {:calendar_events_updated, _user_id, uids}
      assert event.uid in uids
    end

    test "empty list returns :ok without side effects" do
      integration = insert(:calendar_integration)
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{integration.user_id}")

      assert :ok = Sync.persist_normalised_events(integration, [])

      refute_receive {:calendar_events_updated, _, _}, 100
    end

    test "time-changed reconcile (timed event): updates calendar_sync_status when start_at differs" do
      integration = insert(:calendar_integration)

      old_start = DateTime.add(DateTime.utc_now(:second), 3600, :second)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-timed-changed",
          start_time: old_start
        )

      # Build an event with a different start time than the meeting's start_time
      new_start = DateTime.add(old_start, 7200, :second)

      event =
        CalendarEvent.new!(%{
          uid: "timed-changed-uid-#{System.unique_integer([:positive])}",
          calendar_integration_id: integration.id,
          provider: :caldav,
          provider_calendar_id: "/cal/primary",
          provider_event_id: "evt-timed-changed",
          all_day: false,
          start_at: new_start,
          end_at: DateTime.add(new_start, 3600, :second),
          synced_at: DateTime.utc_now(:microsecond)
        })

      assert :ok = Sync.persist_normalised_events(integration, [event])

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_modified"
    end

    test "time-changed reconcile (all-day event): updates calendar_sync_status when start_date differs" do
      integration = insert(:calendar_integration)

      # Meeting stored with start_time representing the original all-day date
      original_date = ~D[2026-06-01]
      original_start_time = DateTime.new!(original_date, ~T[00:00:00], "Etc/UTC")

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "evt-allday-changed",
          start_time: original_start_time
        )

      # Provider now says the event moved to a different date
      new_date = ~D[2026-06-03]
      event = build_all_day_event(integration, "evt-allday-changed", new_date)

      assert :ok = Sync.persist_normalised_events(integration, [event])

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_modified"
    end

    test "time-changed reconcile (CalDAV): matches by uid when the cache row is keyed by href" do
      integration = insert(:calendar_integration)

      old_start = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      uid = "caldav-moved-#{System.unique_integer([:positive])}@tymeslot.com"

      # The CalDAV write path leaves provider_event_id unset on the meeting;
      # the synced copy is keyed by its href. The UID is the only identifier
      # the two sides share.
      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: nil,
          uid: uid,
          start_time: old_start
        )

      new_start = DateTime.add(old_start, 7200, :second)

      event =
        CalendarEvent.new!(%{
          uid: uid,
          calendar_integration_id: integration.id,
          provider: :caldav,
          provider_calendar_id: "/cal/primary",
          provider_event_id: "/cal/primary/#{uid}.ics",
          all_day: false,
          start_at: new_start,
          end_at: DateTime.add(new_start, 3600, :second),
          synced_at: DateTime.utc_now(:microsecond)
        })

      assert :ok = Sync.persist_normalised_events(integration, [event])

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_modified"
    end

    test "leaves an unrelated meeting alone when no identifier matches" do
      integration = insert(:calendar_integration)
      start_time = DateTime.add(DateTime.utc_now(:second), 3600, :second)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: nil,
          uid: "mine-#{System.unique_integer([:positive])}@tymeslot.com",
          start_time: start_time
        )

      event = build_timed_event(integration, "/cal/primary/someone-elses.ics")

      assert :ok = Sync.persist_normalised_events(integration, [event])

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert is_nil(updated.calendar_sync_status)
    end

    test "flags a mirrored booking as ours though its UID carries no Tymeslot marker" do
      integration = insert(:calendar_integration)
      start_time = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      # A booking's UID is a bare UUID, so neither the `@tymeslot.com` suffix
      # nor a provider marker identifies it. The link to the meeting does.
      uid = UUID.generate()

      insert(:meeting,
        calendar_integration_id: integration.id,
        provider_event_id: nil,
        uid: uid,
        start_time: start_time
      )

      event =
        CalendarEvent.new!(%{
          uid: uid,
          calendar_integration_id: integration.id,
          provider: :caldav,
          provider_calendar_id: "/cal/primary",
          provider_event_id: "/cal/primary/#{uid}.ics",
          all_day: false,
          start_at: start_time,
          end_at: DateTime.add(start_time, 3600, :second),
          synced_at: DateTime.utc_now(:microsecond)
        })

      refute event.created_by_tymeslot

      assert :ok = Sync.persist_normalised_events(integration, [event])

      {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
      assert cached.created_by_tymeslot
    end

    test "leaves an unrelated provider event unflagged" do
      integration = insert(:calendar_integration)
      event = build_timed_event(integration, "/cal/primary/someone-elses.ics")

      assert :ok = Sync.persist_normalised_events(integration, [event])

      {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      refute cached.created_by_tymeslot
    end

    test "upsert error: returns {:error, reason} when upsert raises" do
      # Build a valid integration struct but swap in a bogus id before calling
      # persist_normalised_events so the FK in provider_calendar_events fails. The
      # struct still matches the function clause (%CalendarIntegrationSchema{}).
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      bad_integration = %{integration | id: 999_999_999}

      event =
        CalendarEvent.new!(%{
          uid: "err-uid-#{System.unique_integer([:positive])}",
          calendar_integration_id: bad_integration.id,
          provider: :caldav,
          provider_calendar_id: "/cal/primary",
          all_day: false,
          start_at: DateTime.utc_now(:microsecond),
          end_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second),
          synced_at: DateTime.utc_now(:microsecond)
        })

      assert {:error, _reason} = Sync.persist_normalised_events(bad_integration, [event])
    end
  end

  describe "reconcile_deletions/3" do
    alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

    test "deletes the cache row by uid and reconciles the linked meeting" do
      integration = insert(:calendar_integration)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "del-uid-1",
        provider_event_id: "del-evt-1"
      )

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "del-evt-1"
        )

      assert :ok =
               Sync.reconcile_deletions(integration, [
                 %{provider_event_id: "del-evt-1", uid: "del-uid-1"}
               ])

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "del-uid-1")

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_deleted"
      assert updated.status == "cancelled"
    end

    test "falls back to provider_event_id for the cache delete when uid is nil" do
      integration = insert(:calendar_integration)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "del-uid-2",
        provider_event_id: "del-evt-2"
      )

      assert :ok =
               Sync.reconcile_deletions(integration, [
                 %{provider_event_id: "del-evt-2", uid: nil}
               ])

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "del-uid-2")
    end

    test "delete_cache: false reconciles without touching the cache row" do
      integration = insert(:calendar_integration)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "del-uid-3",
        provider_event_id: "del-evt-3"
      )

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "del-evt-3"
        )

      assert :ok =
               Sync.reconcile_deletions(
                 integration,
                 [%{provider_event_id: "del-evt-3", uid: "del-uid-3"}],
                 delete_cache: false
               )

      assert {:ok, _event} = ProviderCalendarEventQueries.get_by_uid(integration.id, "del-uid-3")

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_deleted"
    end

    test "returns :ok for an empty ref list" do
      integration = insert(:calendar_integration)
      assert :ok = Sync.reconcile_deletions(integration, [])
    end
  end
end
