defmodule Tymeslot.Meetings.CalendarMoveTest do
  @moduledoc """
  Whether a booking flagged as moved in the host's calendar can follow it, and
  the move itself. Every refusal is tested by changing one thing about an
  otherwise movable meeting.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.Factory

  @moduletag :meetings
  @moduletag :calendar

  alias Ecto.Changeset
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Meetings.CalendarMove
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_email_mocks()
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "outlook")

    meeting = insert_meeting(user, integration, "evt-1")
    event = insert_event(integration, meeting, "evt-1")

    %{user: user, integration: integration, meeting: meeting, event: event}
  end

  defp insert_meeting(user, integration, event_id, attrs \\ []) do
    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: user.id,
          status: "confirmed",
          calendar_sync_status: "externally_modified",
          calendar_integration_id: integration.id,
          provider_event_id: event_id
        ],
        attrs
      )
    )
  end

  # An event two hours after the meeting, with microseconds on its start.
  defp insert_event(integration, meeting, event_id) do
    start_at = meeting.start_time |> DateTime.add(2, :hour) |> Map.put(:microsecond, {123_456, 6})
    end_at = DateTime.add(meeting.end_time, 2, :hour)

    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "outlook",
      provider_event_id: event_id,
      start_at: start_at,
      end_at: end_at
    )
  end

  defp change_event(event, attrs) do
    event |> Changeset.change(attrs) |> Repo.update!()
  end

  defp change_meeting(meeting, attrs) do
    meeting |> Changeset.change(attrs) |> Repo.update!()
  end

  test "offers the event's time, to the second", %{meeting: meeting, event: event} do
    assert {:ok, %{start_time: s, end_time: e}} = CalendarMove.offer(meeting)
    assert s == DateTime.truncate(event.start_at, :second)
    assert e == DateTime.truncate(event.end_at, :second)
  end

  describe "refuses" do
    test "a meeting that is not flagged", %{meeting: meeting} do
      meeting = change_meeting(meeting, calendar_sync_status: nil)
      assert CalendarMove.offer(meeting) == {:error, :not_flagged}
    end

    test "a flag the host dismissed", %{meeting: meeting} do
      meeting =
        change_meeting(meeting,
          calendar_sync_status_dismissed_at: DateTime.utc_now(:second)
        )

      assert CalendarMove.offer(meeting) == {:error, :not_flagged}
    end

    test "a group meeting", %{meeting: meeting} do
      meeting = change_meeting(meeting, capacity: 5)
      assert CalendarMove.offer(meeting) == {:error, :group_meeting}
    end

    test "a meeting that is not confirmed", %{meeting: meeting} do
      meeting = change_meeting(meeting, status: "awaiting_approval")
      assert CalendarMove.offer(meeting) == {:error, :not_confirmed}
    end

    test "a meeting awaiting a new time after a reschedule request", %{meeting: meeting} do
      meeting = change_meeting(meeting, reschedule_requested_at: DateTime.utc_now(:second))
      assert CalendarMove.offer(meeting) == {:error, :awaiting_new_time}
    end

    test "while Tymeslot's own calendar write is pending", %{meeting: meeting} do
      {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")
      assert CalendarMove.offer(meeting) == {:error, :calendar_write_pending}
    end

    test "a meeting whose event is not cached", %{meeting: meeting, event: event} do
      Repo.delete!(event)
      assert CalendarMove.offer(meeting) == {:error, :event_not_found}
    end

    test "an all-day event", %{meeting: meeting, event: event} do
      change_event(event, all_day: true)
      assert CalendarMove.offer(meeting) == {:error, :all_day}
    end

    test "an event that does not end after it starts", %{meeting: meeting, event: event} do
      change_event(event, end_at: event.start_at)
      assert CalendarMove.offer(meeting) == {:error, :invalid_times}
    end

    test "an event at the meeting's own time", %{meeting: meeting, event: event} do
      change_event(event,
        start_at: %{meeting.start_time | microsecond: {0, 6}},
        end_at: %{meeting.end_time | microsecond: {0, 6}}
      )

      assert CalendarMove.offer(meeting) == {:error, :unchanged}
    end

    test "an event that starts in the past", %{meeting: meeting, event: event} do
      start_at = DateTime.add(DateTime.utc_now(), -2, :hour)
      change_event(event, start_at: start_at, end_at: DateTime.add(start_at, 1, :hour))
      assert CalendarMove.offer(meeting) == {:error, :in_past}
    end
  end

  test "offers lists only the movable meetings", %{
    user: user,
    integration: integration,
    meeting: a
  } do
    # A different start: one confirmed meeting per organiser and start time.
    b =
      insert_meeting(user, integration, "evt-2",
        calendar_sync_status: nil,
        start_time: DateTime.add(a.start_time, 1, :day),
        end_time: DateTime.add(a.end_time, 1, :day)
      )

    insert_event(integration, b, "evt-2")

    assert Map.keys(CalendarMove.offers([a, b])) == [a.id]
  end

  describe "move/3" do
    test "moves the booking and clears the flag", %{user: user, meeting: meeting} do
      {:ok, offer} = CalendarMove.offer(meeting)

      assert {:ok, moved} = CalendarMove.move(meeting.id, user.id, offer)
      assert moved.start_time == offer.start_time
      assert moved.end_time == offer.end_time
      assert moved.calendar_sync_status == nil
    end

    # The event moved again after the host was shown the offer: the booking
    # must not land on a time the host never confirmed.
    test "refuses when the calendar time changed after the host confirmed", %{
      user: user,
      meeting: meeting,
      event: event
    } do
      {:ok, offer} = CalendarMove.offer(meeting)

      later = DateTime.add(event.start_at, 1, :hour)
      change_event(event, start_at: later, end_at: DateTime.add(event.end_at, 1, :hour))

      assert CalendarMove.move(meeting.id, user.id, offer) == {:error, :offer_changed}

      {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert unchanged.start_time == meeting.start_time
      assert unchanged.calendar_sync_status == "externally_modified"

      {:ok, fresh} = CalendarMove.offer(meeting)
      assert {:ok, moved} = CalendarMove.move(meeting.id, user.id, fresh)
      assert moved.start_time == DateTime.truncate(later, :second)
    end

    test "refuses when only the end changed after the host confirmed", %{
      user: user,
      meeting: meeting,
      event: event
    } do
      {:ok, offer} = CalendarMove.offer(meeting)

      change_event(event, end_at: DateTime.add(event.end_at, 15, :minute))

      assert CalendarMove.move(meeting.id, user.id, offer) == {:error, :offer_changed}
    end

    test "a second move is refused", %{user: user, meeting: meeting} do
      {:ok, offer} = CalendarMove.offer(meeting)

      assert {:ok, _moved} = CalendarMove.move(meeting.id, user.id, offer)
      assert CalendarMove.move(meeting.id, user.id, offer) == {:error, :not_flagged}
    end

    test "a move onto another confirmed booking's start is refused", %{
      user: user,
      integration: integration,
      meeting: meeting,
      event: event
    } do
      insert_meeting(user, integration, "evt-other",
        calendar_sync_status: nil,
        start_time: DateTime.truncate(event.start_at, :second),
        end_time: DateTime.truncate(event.end_at, :second)
      )

      {:ok, offer} = CalendarMove.offer(meeting)

      assert CalendarMove.move(meeting.id, user.id, offer) == {:error, :slot_taken}

      {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert unchanged.start_time == meeting.start_time
      assert unchanged.end_time == meeting.end_time
      assert unchanged.calendar_sync_status == "externally_modified"
    end

    test "refuses another organiser's meeting", %{meeting: meeting} do
      other = insert(:user)
      {:ok, offer} = CalendarMove.offer(meeting)

      assert CalendarMove.move(meeting.id, other.id, offer) == {:error, :not_found}

      {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert unchanged.start_time == meeting.start_time
      assert unchanged.calendar_sync_status == "externally_modified"
    end
  end
end
