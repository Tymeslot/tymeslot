defmodule Tymeslot.Workers.BookingRequestEmailsTest do
  @moduledoc """
  The worker side of the approval emails.

  Covers what the job does when it finally runs, which is a different question
  from whether it was enqueued: by then the request may have been answered,
  withdrawn, or already nudged.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  @moduletag :emails
  @moduletag :bookings

  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!
  setup :set_mox_from_context

  defp held_meeting(attrs \\ %{}) do
    user = insert(:user)

    defaults = %{
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  defp request_job(meeting),
    do:
      perform_job(EmailWorker, %{
        "action" => "send_booking_request_emails",
        "meeting_id" => meeting.id
      })

  defp outcome_job(meeting, variant),
    do:
      perform_job(EmailWorker, %{
        "action" => "send_booking_request_outcome",
        "meeting_id" => meeting.id,
        "variant" => variant
      })

  defp nudge_job(meeting),
    do:
      perform_job(EmailWorker, %{
        "action" => "send_booking_approval_nudge",
        "meeting_id" => meeting.id
      })

  describe "send_booking_request_emails" do
    test "sends the invitee's acknowledgement and the host's request" do
      meeting = held_meeting()
      test_pid = self()

      expect(Tymeslot.EmailServiceMock, :send_booking_request_received, fn sent ->
        send(test_pid, {:invitee_email, sent.id})
        {:ok, :sent}
      end)

      expect(Tymeslot.EmailServiceMock, :send_booking_approval_request, fn variant,
                                                                           sent,
                                                                           urls,
                                                                           _locale ->
        send(test_pid, {:host_email, variant, sent.id, urls})
        {:ok, :sent}
      end)

      assert :ok = request_job(meeting)

      assert_received {:invitee_email, id} when id == meeting.id
      assert_received {:host_email, :request, host_id, urls} when host_id == meeting.id
      # The host must receive links that actually resolve to this request.
      assert urls.approve_url =~ "/meeting-request/"
      assert urls.decline_url =~ "intent=decline"
    end

    test "sends nothing once the request has been answered" do
      meeting = held_meeting(%{status: "confirmed"})

      # No `expect` is set: a call to either send function fails the test.
      assert {:discard, _reason} = request_job(meeting)
    end

    test "discards when the meeting has since been deleted" do
      meeting = held_meeting()
      Repo.delete!(meeting)

      assert {:discard, _reason} = request_job(meeting)
    end
  end

  describe "send_booking_approval_nudge" do
    test "reminds the host and records that it did" do
      meeting = held_meeting()
      test_pid = self()

      expect(Tymeslot.EmailServiceMock, :send_booking_approval_request, fn variant,
                                                                           _meeting,
                                                                           _urls,
                                                                           _locale ->
        send(test_pid, {:nudged, variant})
        {:ok, :sent}
      end)

      assert :ok = nudge_job(meeting)
      assert_received {:nudged, :nudge}

      assert %DateTime{} = Repo.reload!(meeting).approval_nudge_sent_at
    end

    test "does not send a second time if a retry re-runs the job" do
      meeting = held_meeting()

      expect(Tymeslot.EmailServiceMock, :send_booking_approval_request, 1, fn _v, _m, _u, _l ->
        {:ok, :sent}
      end)

      assert :ok = nudge_job(meeting)
      # The stored timestamp is what survives a job retry; the Oban unique key
      # cannot help once the job is already running.
      assert :ok = nudge_job(Repo.reload!(meeting))
    end

    test "stays silent for a request the host has already answered" do
      meeting = held_meeting()

      {:ok, _declined} =
        MeetingQueries.transition_from_awaiting_approval(meeting.id, status: "cancelled")

      assert {:discard, _reason} = nudge_job(Repo.reload!(meeting))
    end
  end

  describe "the outcome email" do
    test "sends the declined variant for a request the host refused" do
      meeting = held_meeting(%{status: "cancelled", decline_reason: "Away that week"})

      expect(Tymeslot.EmailServiceMock, :send_booking_request_outcome, fn :declined, sent ->
        assert sent.id == meeting.id
        {:ok, :sent}
      end)

      assert :ok = outcome_job(meeting, "declined")
    end

    test "sends the expired variant for a request nobody answered" do
      meeting = held_meeting(%{status: "expired"})

      expect(Tymeslot.EmailServiceMock, :send_booking_request_outcome, fn :expired, _sent ->
        {:ok, :sent}
      end)

      assert :ok = outcome_job(meeting, "expired")
    end

    test "refuses to tell an invitee a confirmed booking was declined" do
      # The status is the authority, not the job's args. A request returned to
      # the gate and then approved between enqueue and execution must not
      # produce a decline email for a meeting that is going ahead.
      meeting = held_meeting(%{status: "confirmed"})

      assert {:discard, _reason} = outcome_job(meeting, "declined")
    end

    test "refuses to call an expiry a decline" do
      meeting = held_meeting(%{status: "expired"})

      assert {:discard, _reason} = outcome_job(meeting, "declined")
    end
  end
end
