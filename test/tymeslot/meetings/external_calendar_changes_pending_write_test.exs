defmodule Tymeslot.Meetings.ExternalCalendarChangesPendingWriteTest do
  @moduledoc """
  A sync can see a calendar event before Tymeslot's own write to it has
  landed (an attendee reschedule moves the booking at once and the calendar a
  few seconds later). Flagging then would offer the host to undo the
  attendee's reschedule, so a modification is not flagged while such a write
  is pending, nor when one completed after the read of the event began.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query
  import Tymeslot.Factory

  @moduletag :meetings
  @moduletag :calendar

  alias Oban.Job
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Meetings.ExternalCalendarChanges
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_email_mocks()

    user = insert(:user)
    integration = insert(:calendar_integration, user: user)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: :confirmed,
        calendar_integration_id: integration.id,
        provider_event_id: "evt-pending"
      )

    %{meeting: meeting, integration: integration}
  end

  # The host is told from an email job, so what the change itself leaves
  # behind is that job.
  defp assert_host_notice(meeting) do
    assert_enqueued(
      worker: Tymeslot.Workers.EmailWorker,
      args: %{"action" => "send_external_booking_change", "meeting_id" => meeting.id}
    )
  end

  defp refute_host_notice do
    refute_enqueued(
      worker: Tymeslot.Workers.EmailWorker,
      args: %{"action" => "send_external_booking_change"}
    )
  end

  defp reload(meeting) do
    {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
    reloaded
  end

  defp calendar_job(meeting, fields) do
    {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")
    Repo.update_all(from(j in Job), set: fields)
  end

  defp modified_from_read_at(integration, read_at) do
    ExternalCalendarChanges.apply_change(integration.id, "evt-pending", nil, :modified,
      snapshot_at: read_at
    )
  end

  describe "a write still pending" do
    test "a modification seen while Tymeslot's own write is queued does not flag the meeting",
         %{meeting: meeting} do
      {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")

      assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :modified)

      assert reload(meeting).calendar_sync_status == nil
      refute_host_notice()
    end

    for state <- ~w(scheduled executing retryable) do
      test "a #{state} write holds the modification back", %{meeting: meeting} do
        calendar_job(meeting, state: unquote(state))

        assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :modified)

        assert reload(meeting).calendar_sync_status == nil
        refute_host_notice()
      end
    end

    test "once that write has finished, the modification flags the meeting and tells the host",
         %{meeting: meeting} do
      calendar_job(meeting, state: "completed")

      assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :modified)

      assert reload(meeting).calendar_sync_status == :externally_modified
      assert_host_notice(meeting)
    end

    # Neither wrote anything to the calendar, so nothing is still to land and
    # the divergence is the host's to know about.
    for state <- ~w(discarded cancelled) do
      test "a #{state} write does not hold the modification back", %{meeting: meeting} do
        calendar_job(meeting, state: unquote(state))

        assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :modified)

        assert reload(meeting).calendar_sync_status == :externally_modified
      end
    end

    test "a deletion is applied whatever is queued", %{meeting: meeting} do
      {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")

      assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :deleted)

      assert %{calendar_sync_status: :externally_deleted, status: :cancelled} = reload(meeting)
    end
  end

  # The sync reads the event, then pages, refreshes series and writes the
  # cache before it reconciles. A write that completes in between is no
  # longer pending when asked, yet may have landed after the event was read.
  describe "a write completed after the event was read" do
    test "holds the modification back", %{meeting: meeting, integration: integration} do
      read_at = DateTime.utc_now()
      calendar_job(meeting, state: "completed", completed_at: DateTime.add(read_at, 2, :second))

      assert :ok = modified_from_read_at(integration, read_at)

      assert reload(meeting).calendar_sync_status == nil
      refute_host_notice()
    end

    test "a write completed before the read does not", %{
      meeting: meeting,
      integration: integration
    } do
      read_at = DateTime.utc_now()
      calendar_job(meeting, state: "completed", completed_at: DateTime.add(read_at, -2, :second))

      assert :ok = modified_from_read_at(integration, read_at)

      assert reload(meeting).calendar_sync_status == :externally_modified
      assert_host_notice(meeting)
    end

    test "a write discarded after the read does not", %{
      meeting: meeting,
      integration: integration
    } do
      read_at = DateTime.utc_now()
      calendar_job(meeting, state: "discarded", discarded_at: DateTime.add(read_at, 2, :second))

      assert :ok = modified_from_read_at(integration, read_at)

      assert reload(meeting).calendar_sync_status == :externally_modified
    end

    test "a deletion is applied all the same", %{meeting: meeting, integration: integration} do
      read_at = DateTime.utc_now()
      calendar_job(meeting, state: "completed", completed_at: DateTime.add(read_at, 2, :second))

      assert :ok =
               ExternalCalendarChanges.apply_change(integration.id, "evt-pending", nil, :deleted,
                 snapshot_at: read_at
               )

      assert %{calendar_sync_status: :externally_deleted, status: :cancelled} = reload(meeting)
    end
  end
end
