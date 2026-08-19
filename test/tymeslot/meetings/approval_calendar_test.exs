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

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :calendar

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Workers.CalendarEventWorker

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

  test "a booking with no provider event has nothing to flip" do
    meeting = held_meeting(%{provider_event_id: nil})

    {:ok, _confirmed} = Approval.approve(meeting)

    # No integration wrote an event, so scheduling an update would give the
    # worker a meeting it can only fail on.
    refute_enqueued(worker: CalendarEventWorker, args: %{"meeting_id" => meeting.id})
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
end
