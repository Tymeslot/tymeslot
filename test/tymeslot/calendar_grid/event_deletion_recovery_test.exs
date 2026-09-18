defmodule Tymeslot.CalendarGrid.EventDeletionRecoveryTest do
  @moduledoc """
  `CalendarGrid.delete_event/2` once the provider has already removed the
  event. Everything after that point is local tidying: the linked meeting,
  the cached row the grid reads, and the organiser's cached availability.
  None of it can put the event back, so none of it may be reported as a
  failed delete. The organiser would be told to retry a delete that already
  happened, and told nothing about the booking left standing.

  The failures are injected at the two query modules the steps go through,
  which stand in for the database refusing the write; there is no other way
  to reach these paths, and `:meck` is the tool the suite already uses for
  it (see `Tymeslot.Meetings.ApprovalSweepTest`). It replaces a module for
  the whole VM, hence `async: false`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.MeetingCalendarQueries
  alias Tymeslot.Meetings.MeetingQueries

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    caldav =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    event =
      insert(:provider_calendar_event,
        calendar_integration: caldav,
        uid: "event-#{System.unique_integer([:positive])}",
        summary: "Design review",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/design-review.ics",
        start_at: ~U[2026-06-01 09:00:00.000000Z],
        end_at: ~U[2026-06-01 10:00:00.000000Z],
        all_day: false,
        sync_state: "synced"
      )

    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

    %{user: user, caldav: caldav, event: event}
  end

  # `:no_link` keeps the mock alive until `on_exit` takes it down: linked to
  # the test process it is unloaded the moment that process finishes, and the
  # unload below then fails with `:not_mocked`.
  defp stub_module(module, function, implementation) do
    :meck.new(module, [:passthrough, :no_link])
    :meck.expect(module, function, implementation)
    on_exit(fn -> :meck.unload(module) end)
  end

  defp link_meeting(caldav, event) do
    insert(:meeting,
      calendar_integration_id: caldav.id,
      provider_event_id: event.provider_event_id,
      attendee_email: "guest@example.com"
    )
  end

  describe "delete_event/2 when the cached row cannot be removed" do
    test "still reports the delete as done", %{user: user, caldav: caldav, event: event} do
      stub_module(ProviderCalendarEventQueries, :delete_by_uid, fn _id, _uid ->
        raise "database unavailable"
      end)

      assert {:ok, result} = CalendarGrid.delete_event(user.id, event)
      assert result == %{uid: event.uid, integration_id: caldav.id, linked_meeting: :none}

      # The row outlives its event until the next sync removes it, which is
      # the cost of not lying to the organiser about the delete.
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
    end

    test "still invalidates the organiser's cached availability", %{user: user, event: event} do
      stub_module(ProviderCalendarEventQueries, :delete_by_uid, fn _id, _uid ->
        raise "database unavailable"
      end)

      key = AvailabilityCache.booking_window_events_key(user.id)
      :ok = AvailabilityCache.put(key, :stale)

      assert {:ok, _result} = CalendarGrid.delete_event(user.id, event)
      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end
  end

  describe "delete_event/2 when the linked meeting cannot be cancelled" do
    test "reports the failed cancellation rather than a failed delete", %{
      user: user,
      caldav: caldav,
      event: event
    } do
      meeting = link_meeting(caldav, event)

      # The meeting was deleted between the lookup and the cancellation.
      stub_module(MeetingCalendarQueries, :update_calendar_sync_status_if_changed, fn _id,
                                                                                      _status ->
        {:error, :not_found}
      end)

      assert {:ok, %{linked_meeting: :cancel_failed}} = CalendarGrid.delete_event(user.id, event)
      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)

      {:ok, untouched} = MeetingQueries.get_meeting(meeting.id)
      assert {untouched.status, untouched.calendar_sync_status} == {"confirmed", nil}
    end

    test "reports a cancellation that crashed the same way", %{
      user: user,
      caldav: caldav,
      event: event
    } do
      link_meeting(caldav, event)

      stub_module(MeetingCalendarQueries, :update_calendar_sync_status_if_changed, fn _id,
                                                                                      _status ->
        raise "database unavailable"
      end)

      assert {:ok, %{linked_meeting: :cancel_failed}} = CalendarGrid.delete_event(user.id, event)
      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
    end
  end
end
