defmodule Tymeslot.CalendarGrid.EventMoveReportedTest do
  @moduledoc """
  `Changes.move_event_reported/4` answers a move in the shape the calendar
  and the write guardian read (`{:event_move_result, result}`), and
  `move_crash_report/2` in the shape a crashed move answers in.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Integrations.Calendar.CreatedEvent

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    source =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/src/"])

    event =
      insert(:provider_calendar_event,
        calendar_integration: source,
        provider: "caldav",
        provider_calendar_id: "/src/",
        provider_event_id: "/src/review.ics",
        summary: "Design review",
        start_at: ~U[2026-06-01 09:00:00.000000Z],
        end_at: ~U[2026-06-01 10:00:00.000000Z],
        all_day: false,
        sync_state: "synced"
      )

    %{user: user, event: event}
  end

  test "a move that landed names the new identity and the event it moved", %{
    user: user,
    event: event
  } do
    destination =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/dest/"])

    expect(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

    assert {:ok, report} =
             Changes.move_event_reported(
               user.id,
               event,
               %{integration: destination, calendar_id: "/dest/"},
               nil
             )

    assert report[:integration_id] == destination.id
    assert is_binary(report[:uid]) and report[:uid] != event.uid
    assert report[:source] == nil
    assert report[:original_event].id == event.id
    refute Keyword.has_key?(report, :series_to)
  end

  test "a refused move names the reason and the event, and carries the series' destination",
       %{user: user, event: event} do
    nowhere =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: [])

    expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> :ok end)

    assert {:error, report} =
             Changes.move_event_reported(
               user.id,
               event,
               %{integration: nowhere, calendar_id: nil},
               "Family"
             )

    assert report[:reason] == :no_destination_calendar
    assert report[:original_event].id == event.id
    assert report[:series_to] == "Family"
  end

  test "a crashed move answers as a failure of the event it was moving", %{event: event} do
    assert Changes.move_crash_report(event, nil) ==
             {:error, [original_event: event, reason: :crashed]}

    assert {:error, report} = Changes.move_crash_report(event, "Family")
    assert report[:series_to] == "Family"
  end
end
