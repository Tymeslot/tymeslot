defmodule Tymeslot.Emails.EmailScheduler.MeetingSchedulerRequestEmailsTest do
  @moduledoc """
  `MeetingScheduler.schedule_request_emails/2` while an earlier pair of
  request emails for the same meeting is still waiting or retrying.
  """

  use Tymeslot.DataCase, async: true

  import Ecto.Query
  import Tymeslot.Factory

  @moduletag :emails
  @moduletag :bookings

  alias Oban.Job
  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler

  @action "send_booking_request_emails"
  @first_deadline ~U[2026-12-01 09:00:00Z]
  @second_deadline ~U[2026-12-08 09:00:00Z]
  @moved_from ~U[2026-12-02 10:00:00Z]

  setup do
    %{meeting: insert(:meeting, status: :awaiting_approval)}
  end

  describe "a reschedule back into the gate while the first pair is pending" do
    for state <- ~w(available retryable) do
      test "replaces the pending pair (#{state}) with one for the new request", %{
        meeting: meeting
      } do
        assert :ok =
                 MeetingScheduler.schedule_request_emails(meeting.id,
                   relevant_until: @first_deadline
                 )

        [first] = request_jobs(meeting.id)
        mark(first, unquote(state))

        assert :ok =
                 MeetingScheduler.schedule_request_emails(meeting.id,
                   relevant_until: @second_deadline,
                   previous_start_time: @moved_from
                 )

        assert [second] = request_jobs(meeting.id)
        assert second.id != first.id
        assert second.args["relevant_until"] == DateTime.to_iso8601(@second_deadline)
        assert second.args["previous_start_time"] == DateTime.to_iso8601(@moved_from)
      end
    end
  end

  test "a repeated call for the same request keeps the pending pair", %{meeting: meeting} do
    opts = [relevant_until: @first_deadline, previous_start_time: @moved_from]

    assert :ok = MeetingScheduler.schedule_request_emails(meeting.id, opts)
    [first] = request_jobs(meeting.id)
    mark(first, "retryable")

    assert :ok = MeetingScheduler.schedule_request_emails(meeting.id, opts)

    assert [kept] = request_jobs(meeting.id)
    assert kept.id == first.id
  end

  test "leaves another meeting's pending pair alone", %{meeting: meeting} do
    other = insert(:meeting, status: :awaiting_approval)

    assert :ok =
             MeetingScheduler.schedule_request_emails(other.id, relevant_until: @first_deadline)

    assert :ok =
             MeetingScheduler.schedule_request_emails(meeting.id,
               relevant_until: @second_deadline
             )

    assert [_still_there] = request_jobs(other.id)
  end

  defp request_jobs(meeting_id) do
    Repo.all(
      from j in Job,
        where:
          fragment("? @> ?::jsonb", j.args, ^%{"action" => @action, "meeting_id" => meeting_id}),
        where: j.state not in ["completed", "discarded", "cancelled"]
    )
  end

  defp mark(%Job{id: id}, state) do
    Repo.update_all(from(j in Job, where: j.id == ^id), set: [state: state])
  end
end
