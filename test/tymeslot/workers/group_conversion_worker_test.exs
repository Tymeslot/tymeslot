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

  test "perform/1 returns an error tuple when a batch fails to convert, so Oban retries", %{
    meeting_type: meeting_type,
    meeting: meeting
  } do
    # No attendee timezone still passes the convertible-bookings query (which
    # only checks for an email), but violates the participant changeset's
    # required field, so the insert fails and the failure must propagate
    # rather than being swallowed as a silent skip.
    {:ok, _meeting} = MeetingQueries.update_meeting(meeting, %{attendee_timezone: nil})

    assert {:error, _reason} =
             perform_job(GroupConversionWorker, %{
               "meeting_type_id" => meeting_type.id,
               "capacity" => 4
             })

    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
  end

  test "enqueue/2 deduplicates jobs for the same meeting type" do
    assert {:ok, %{conflict?: false}} = GroupConversionWorker.enqueue(123, 4)
    assert {:ok, %{conflict?: true}} = GroupConversionWorker.enqueue(123, 4)

    assert_enqueued(
      worker: GroupConversionWorker,
      args: %{"meeting_type_id" => 123, "capacity" => 4}
    )
  end
end
