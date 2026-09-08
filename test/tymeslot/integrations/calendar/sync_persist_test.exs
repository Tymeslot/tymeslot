defmodule Tymeslot.Integrations.Calendar.SyncPersistTest do
  @moduledoc """
  Covers `Sync.persist_normalised_events/2`: the cache write itself, the
  ownership flag it stamps on the way in, and the post-commit pass that
  reconciles a linked meeting against the times the provider now reports.

  Split from `Tymeslot.Integrations.Calendar.SyncTest`, which covers the
  reconciliation entry points (`reconcile/4`, `reconcile_deletions/3`) that a
  sync worker calls directly.
  """
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

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
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

    test "clears a stale externally_modified flag once the times agree again" do
      integration = insert(:calendar_integration)

      start_time = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      uid = "resolved-#{System.unique_integer([:positive])}@tymeslot.com"

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: nil,
          uid: uid,
          start_time: start_time,
          calendar_sync_status: "externally_modified",
          calendar_sync_status_dismissed_at: DateTime.utc_now(:second)
        )

      # The provider now agrees with the booking again — the host put the time
      # back, or our own write to the calendar finally landed.
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

      assert :ok = Sync.persist_normalised_events(integration, [event])

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == nil
      assert updated.calendar_sync_status_dismissed_at == nil
    end

    test "leaves an externally_deleted meeting flagged when a matching event reappears" do
      integration = insert(:calendar_integration)

      start_time = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      uid = "still-deleted-#{System.unique_integer([:positive])}@tymeslot.com"

      # The deletion signal auto-cancelled the meeting, and the status is the
      # record of why. Agreement about the time must not erase it.
      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: nil,
          uid: uid,
          start_time: start_time,
          status: "cancelled",
          calendar_sync_status: "externally_deleted"
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

      assert :ok = Sync.persist_normalised_events(integration, [event])

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_deleted"
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
end
