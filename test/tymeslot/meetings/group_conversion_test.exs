defmodule Tymeslot.Meetings.GroupConversionTest do
  @moduledoc """
  Coverage for the solo -> group migration that runs when a meeting type
  gains a participant limit above 1.

  The bookings taken while the type was solo live in the meeting row's
  `attendee_*` columns, which seat maths cannot see. Left alone, the sitting
  attendee's seat reads as free and the next booker joins their 1:1.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Meetings.GroupConversion
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.MeetingTypes

  # The conversion now runs off the request path: `update_meeting_type/3`
  # only enqueues `Tymeslot.Workers.GroupConversionWorker`. Draining the
  # queue runs it synchronously so tests can assert on the result, mirroring
  # the "worker chain" pattern for A-enqueues-B coverage.
  defp run_pending_conversion do
    assert %{success: success, failure: 0} = Oban.drain_queue(queue: :default)
    success
  end

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 1)

    meeting =
      insert(
        :meeting,
        [
          organizer_user_id: user.id,
          meeting_type_ref: meeting_type,
          attendee_name: "Solo Booker",
          attendee_email: "solo@example.com",
          attendee_timezone: "Europe/Berlin"
        ] ++ slot_in(3)
      )

    %{user: user, meeting_type: meeting_type, meeting: meeting}
  end

  # The meetings table checks end_time > start_time, so both move together.
  defp slot_in(days) do
    start_time = DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
    [start_time: start_time, end_time: DateTime.add(start_time, 30, :minute)]
  end

  test "switching a type to group bookings gives its bookings a seat",
       %{meeting_type: meeting_type, meeting: meeting} do
    assert Seats.seats_taken(meeting.id) == 0

    {:ok, updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant.name == "Solo Booker"
    assert participant.email == "solo@example.com"
    assert participant.timezone == "Europe/Berlin"
    assert participant.management_token

    # The sitting booking now occupies a seat, so only three remain.
    assert Seats.seats_left(meeting, updated.max_participants) == 3
  end

  test "the existing booking's guests are adopted so they count too",
       %{meeting_type: meeting_type, meeting: meeting} do
    {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["plus-one@example.com"])

    {:ok, _updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()

    [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert [%{email: "plus-one@example.com"}] = GuestQueries.list_for_participant(participant.id)
    assert Seats.seats_taken(meeting.id) == 2
  end

  test "raising an already-group limit converts nothing", %{user: user} do
    group_type = insert(:meeting_type, user: user, max_participants: 3)

    meeting =
      insert(
        :meeting,
        [
          organizer_user_id: user.id,
          meeting_type_ref: group_type,
          attendee_name: nil,
          attendee_email: nil
        ] ++ slot_in(5)
      )

    {:ok, _updated} = MeetingTypes.update_meeting_type(group_type, %{max_participants: 8})
    run_pending_conversion()

    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
  end

  test "past bookings are left alone", %{user: user, meeting_type: meeting_type} do
    past =
      insert(
        :meeting,
        [
          organizer_user_id: user.id,
          meeting_type_ref: meeting_type,
          attendee_name: "Last Week",
          attendee_email: "past@example.com"
        ] ++ slot_in(-7)
      )

    {:ok, _updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()

    assert ParticipantQueries.list_live_for_meeting(past.id) == []
  end

  test "converting twice does not double up", %{meeting_type: meeting_type, meeting: meeting} do
    {:ok, _first} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()
    assert {:ok, 0} = GroupConversion.backfill(meeting_type.id, 4)

    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 1
  end

  test "the converted meeting's own capacity is snapshotted, not just its participant",
       %{meeting_type: meeting_type, meeting: meeting} do
    assert meeting.capacity == 1

    {:ok, _updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()

    assert {:ok, %{capacity: 4}} = MeetingQueries.get_meeting(meeting.id)
  end
end
