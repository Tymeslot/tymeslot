defmodule Tymeslot.CalendarGrid.EventEditAttendeesTest do
  @moduledoc """
  Which grid edits carry the attendee list to the provider.

  Every grid write sends the whole event (`CalendarGrid.EventEdit`), with the
  guest list as the one exception. Google's update is a `PUT` and needs the
  list on every write. Outlook's `PATCH` resets every reply in an attendee
  array it is sent, and a patched CalDAV document takes a supplied list as the
  complete new one, so those writes carry attendees only when the edit is
  about them.

  The provider write is stubbed at the suite-wide `:calendar_module` seam, as
  in `EventEditTest`; `EventEditCalDAVWriteTest` follows the CalDAV write the
  whole way to the document the server receives.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Outlook.EventMapper, as: OutlookMapper

  setup :verify_on_exit!

  @attendees [%{"email" => "guest@example.com", "name" => "Guest", "status" => "accepted"}]
  @raw_ical "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"

  setup do
    %{user: insert(:user)}
  end

  defp insert_event(user, provider, attrs \\ %{}) do
    integration = insert(:calendar_integration, user: user, provider: provider)

    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Weekly sync",
      provider: provider,
      provider_calendar_id: "team-calendar",
      provider_event_id: "/cal/weekly-sync.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      attendees: @attendees,
      etag: "\"etag-1\"",
      raw_ical: @raw_ical,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp expect_provider_update do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_update, payload})
      :ok
    end)
  end

  defp captured_payload do
    assert_received {:provider_update, payload}
    payload
  end

  describe "an Outlook edit" do
    test "a rename sends no attendees", %{user: user} do
      event = insert_event(user, "outlook")
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      payload = captured_payload()
      assert payload.summary == "Renamed"
      refute Map.has_key?(payload, :attendees)
    end

    # The empty cached list is the case that used to wipe the guests: it went
    # out as `"attendees" => []` and Graph replaced the collection with it.
    test "a rename of an event cached with no attendees puts no attendees in the body", %{
      user: user
    } do
      event = insert_event(user, "outlook", %{attendees: []})
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      body = OutlookMapper.format_event_data(captured_payload())
      assert body["subject"] == "Renamed"
      refute Map.has_key?(body, "attendees")
    end

    test "removing the last guest sends the empty list", %{user: user} do
      event = insert_event(user, "outlook")
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{attendees: []})

      assert OutlookMapper.format_event_data(captured_payload())["attendees"] == []
    end
  end

  describe "a CalDAV edit" do
    test "a rename patched onto the stored document sends no attendees", %{user: user} do
      event = insert_event(user, "caldav")
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      payload = captured_payload()
      assert payload.raw_ical == @raw_ical
      refute Map.has_key?(payload, :attendees)
    end

    # Without a stored document the adapter rebuilds the event from the
    # payload, so a list left out would be a list deleted.
    test "a rename with no stored document still sends the whole list", %{user: user} do
      event = insert_event(user, "caldav", %{raw_ical: nil, etag: nil})
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      assert captured_payload().attendees == @attendees
    end
  end

  test "a Google rename still sends the whole list", %{user: user} do
    event = insert_event(user, "google")
    expect_provider_update()

    assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

    assert captured_payload().attendees == @attendees
  end
end
