defmodule Tymeslot.Workers.GroupConversionWorkerTest do
  @moduledoc """
  Coverage for the worker that runs `Tymeslot.Meetings.GroupConversion` off
  the request path: successful execution, the retry-on-batch-failure path,
  and that `enqueue/2` is unique per meeting type.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings
  @moduletag :workers

  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Profiles
  alias Tymeslot.Workers.GroupConversionWorker

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 4)

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

    %{meeting_type: meeting_type, meeting: meeting}
  end

  defp slot_in(days) do
    start_time = DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
    [start_time: start_time, end_time: DateTime.add(start_time, 30, :minute)]
  end

  test "perform/1 converts the type's convertible bookings", %{
    meeting_type: meeting_type,
    meeting: meeting
  } do
    assert :ok =
             perform_job(GroupConversionWorker, %{
               "meeting_type_id" => meeting_type.id,
               "capacity" => 4
             })

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant.email == "solo@example.com"
  end

  test "perform/1 still converts a booking with no attendee timezone, via the organiser's own",
       %{meeting_type: meeting_type, meeting: meeting} do
    # No attendee timezone still passes the convertible-bookings query (which
    # only checks for an email); it used to violate the participant
    # changeset's required field and poison the whole job. It no longer
    # does: `Tymeslot.Meetings.GroupConversion` falls back to the organiser's
    # own timezone for exactly this case.
    {:ok, _meeting} = MeetingQueries.update_meeting(meeting, %{attendee_timezone: nil})

    assert :ok =
             perform_job(GroupConversionWorker, %{
               "meeting_type_id" => meeting_type.id,
               "capacity" => 4
             })

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant.timezone == Profiles.get_user_timezone(meeting.organizer_user_id)
  end

  test "enqueue/2 deduplicates a repeated enqueue at the same capacity" do
    assert {:ok, %{conflict?: false}} = GroupConversionWorker.enqueue(123, 4)
    assert {:ok, %{conflict?: true}} = GroupConversionWorker.enqueue(123, 4)

    assert_enqueued(
      worker: GroupConversionWorker,
      args: %{"meeting_type_id" => 123, "capacity" => 4}
    )
  end

  # An organiser correcting the capacity shortly after the first save must
  # not have that correction silently dropped by the same uniqueness that
  # rightly collapses two identical toggles. `Tymeslot.Meetings.GroupConversion`
  # re-stamps an already-converted meeting's capacity precisely so this
  # second job is not wasted.
  test "enqueue/2 does not deduplicate a re-enqueue at a different capacity" do
    assert {:ok, %{conflict?: false}} = GroupConversionWorker.enqueue(123, 10)
    assert {:ok, %{conflict?: false}} = GroupConversionWorker.enqueue(123, 3)

    assert_enqueued(
      worker: GroupConversionWorker,
      args: %{"meeting_type_id" => 123, "capacity" => 10}
    )

    assert_enqueued(
      worker: GroupConversionWorker,
      args: %{"meeting_type_id" => 123, "capacity" => 3}
    )
  end
end
