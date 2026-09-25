defmodule Tymeslot.Meetings.ApprovalCalendarTest do
  @moduledoc """
  What happens to the host's calendar event when a request is approved.

  The booking wrote a tentative event to hold the slot. Approving it has to
  flip that event to confirmed, or the host's calendar keeps showing a
  maybe for a meeting they agreed to, and every other app reading that
  calendar (including their colleagues' free/busy) reads it as provisional.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  @moduletag :bookings
  @moduletag :calendar

  alias Ecto.Changeset
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  defp held_meeting(attrs \\ %{}) do
    user = insert(:user)

    defaults = %{
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      provider_event_id: "provider-event-1",
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  test "approving schedules the update that turns the hold into a real booking" do
    meeting = held_meeting()

    {:ok, _confirmed} = Approval.approve(meeting)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => meeting.id}
    )
  end

  test "approving a CalDAV booking still schedules the flip" do
    # CalDAV never stamps `provider_event_id`; it addresses its event by
    # `uid` alone, and that `uid` is the meeting's own id (a UUID) until the
    # create job overwrites it. A gate that only recognised a present
    # `provider_event_id` or a `uid` that didn't look like a plain UUID was
    # therefore permanently false for every CalDAV host, and their calendars
    # kept showing TENTATIVE forever regardless of approval — this is the
    # regression test for that: no gate at all, the update job is scheduled
    # unconditionally and is itself responsible for falling back to
    # uid-addressing.
    meeting = held_meeting(%{provider_event_id: nil})

    {:ok, _confirmed} = Approval.approve(meeting)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => meeting.id}
    )
  end

  test "declining removes the hold rather than updating it" do
    meeting = held_meeting()

    {:ok, _declined} = Approval.decline(meeting, nil)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "delete", "meeting_id" => meeting.id}
    )

    refute_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => meeting.id}
    )
  end

  describe "an approved booking with a video meeting" do
    # Approval enqueues the update that confirms the event and the job that
    # creates the room. The room lands while that update is still writing, so
    # the link reaches the calendar only through a second update, which must
    # neither be dropped as a duplicate of the first nor race it to the server.
    test "gains the video link on the host's calendar entry" do
      meeting = held_video_meeting()
      room_url = "https://test.mirotalk.com/join/approved-room"

      {:ok, _confirmed} = Approval.approve(meeting)

      [approval_update] = enqueued_updates(meeting)
      approval_update = start_executing(approval_update, ~U[2026-01-01 12:00:00.000000Z])

      expect_mirotalk_success(room_url)
      [room_job] = all_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
      assert :ok = perform_job(VideoRoomWorker, room_job.args)
      assert Repo.get!(MeetingSchema, meeting.id).meeting_url == room_url

      [link_update] = enqueued_updates(meeting)
      link_update = start_executing(link_update, ~U[2026-01-01 12:00:01.000000Z])

      assert {:snooze, _seconds} = CalendarEventWorker.perform(link_update)

      finish(approval_update)
      test_pid = self()

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _integration_id ->
        send(test_pid, {:calendar_update, event_data})
        :ok
      end)

      assert :ok = CalendarEventWorker.perform(link_update)
      assert_received {:calendar_update, %{location: ^room_url, description: description}}
      assert description =~ room_url
    end
  end

  defp held_video_meeting do
    %{user: user, meeting: calendar_meeting} = setup_calendar_scenario()
    _profile = insert(:profile, user: user)
    video = insert(:video_integration, user: user, provider: "mirotalk")

    calendar_meeting
    |> Changeset.change(
      status: "awaiting_approval",
      organizer_email: user.email,
      video_integration_id: video.id,
      provider_event_id: "provider-event-1",
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
    )
    |> Repo.update!()
  end

  defp enqueued_updates(meeting) do
    all_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => meeting.id}
    )
  end

  # Oban's uniqueness and the worker's wait both read the job's row, so moving
  # the row is what puts the job in flight as far as either can tell.
  defp start_executing(job, attempted_at) do
    job
    |> Changeset.change(state: "executing", attempt: 1, attempted_at: attempted_at)
    |> Repo.update!()
  end

  defp finish(job) do
    job
    |> Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()
  end
end
