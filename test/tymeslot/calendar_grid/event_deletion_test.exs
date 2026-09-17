defmodule Tymeslot.CalendarGrid.EventDeletionTest do
  @moduledoc """
  `CalendarGrid.delete_event/2` deletes an event on its calendar, cancels the
  Tymeslot meeting it was booked as, and removes the cached row, or queues the
  delete for the next sync when the calendar could not be reached.

  The provider delete is stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`), where `Calendar.Events.delete_event/3`
  dispatches.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    caldav =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    %{user: user, caldav: caldav}
  end

  defp insert_event(integration, attrs \\ %{}) do
    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Design review",
      provider: integration.provider,
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/design-review.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp expect_delete(result) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :delete_event, fn uid, context, opts ->
      send(test_pid, {:deleted, uid, context, opts})
      result
    end)
  end

  describe "delete_event/2 when the calendar deletes the event" do
    test "addresses the event by its provider id and removes the cached row", %{
      user: user,
      caldav: caldav
    } do
      event = insert_event(caldav)
      expect_delete(:ok)

      assert {:ok, result} = CalendarGrid.delete_event(user.id, event)

      assert result == %{uid: event.uid, integration_id: caldav.id, linked_meeting: :none}
      assert_received {:deleted, uid, context, opts}

      assert {uid, context, opts} ==
               {event.uid, {caldav.id, user.id}, [provider_event_id: "/cal/design-review.ics"]}

      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
    end

    test "invalidates the organiser's cached availability", %{user: user, caldav: caldav} do
      event = insert_event(caldav)
      expect_delete(:ok)

      key = AvailabilityCache.booking_window_events_key(user.id)
      :ok = AvailabilityCache.put(key, :stale)

      assert {:ok, _result} = CalendarGrid.delete_event(user.id, event)
      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end

    test "addresses an event without a provider id by its uid", %{user: user, caldav: caldav} do
      event = insert_event(caldav, %{provider_event_id: nil})
      expect_delete(:ok)

      assert {:ok, _result} = CalendarGrid.delete_event(user.id, event)
      assert_received {:deleted, _uid, _context, []}
    end

    test "cancels the meeting the event was booked as", %{user: user, caldav: caldav} do
      TestMocks.setup_email_mocks()
      event = insert_event(caldav)

      meeting =
        insert(:meeting,
          calendar_integration_id: caldav.id,
          provider_event_id: event.provider_event_id,
          attendee_email: "guest@example.com"
        )

      expect_delete(:ok)

      assert {:ok, %{linked_meeting: :cancelled}} = CalendarGrid.delete_event(user.id, event)

      {:ok, cancelled} = MeetingQueries.get_meeting(meeting.id)

      assert {cancelled.status, cancelled.calendar_sync_status} ==
               {"cancelled", "externally_deleted"}
    end
  end

  describe "delete_event/2 when the calendar refuses the delete" do
    test "queues a CalDAV delete for the next sync", %{user: user, caldav: caldav} do
      event = insert_event(caldav)
      expect_delete({:error, :network_error})
      key = AvailabilityCache.booking_window_events_key(user.id)
      :ok = AvailabilityCache.put(key, :stale)

      assert {:error, %{reason: :network_error, retry: :queued}} =
               CalendarGrid.delete_event(user.id, event)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert row.sync_state == "locally_deleted"
      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end

    test "does not queue a delete a retry cannot recover", %{user: user, caldav: caldav} do
      event = insert_event(caldav)
      expect_delete({:error, :unauthorized})

      assert {:error, %{reason: :unauthorized, retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, event)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert {row.sync_state, row.summary} == {"synced", "Design review"}
    end

    test "leaves the linked meeting alone", %{user: user, caldav: caldav} do
      event = insert_event(caldav)

      meeting =
        insert(:meeting,
          calendar_integration_id: caldav.id,
          provider_event_id: event.provider_event_id
        )

      expect_delete({:error, :network_error})

      assert {:error, _failure} = CalendarGrid.delete_event(user.id, event)

      {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert {unchanged.status, unchanged.calendar_sync_status} == {meeting.status, nil}
    end

    test "keeps the event on a calendar without an offline queue", %{user: user} do
      google = insert(:calendar_integration, user: user, provider: "google")
      event = insert_event(google, %{provider_calendar_id: "primary"})
      expect_delete({:error, :network_error})

      assert {:error, %{reason: :network_error, retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, event)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(google.id, event.uid)
      assert row.sync_state == "synced"
    end
  end
end
