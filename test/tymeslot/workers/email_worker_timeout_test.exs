defmodule Tymeslot.Workers.EmailWorkerTimeoutTest do
  # async: false — the timeout and the send deadline are global application
  # env, which must not race with other email-worker tests running concurrently.
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  describe "perform/1 — delivery timeout" do
    setup do
      setup_config(:tymeslot, :email_timeout_ms, 50)
    end

    test "discards instead of retrying when a send outlives the timeout" do
      user = insert(:unverified_user)

      # Simulate an SMTP send that never returns within the timeout window. Such a
      # send may well have been delivered, so the job must discard rather than let
      # Oban re-send it (which is what produces duplicate emails). Blocking on a
      # message that never arrives keeps this deterministic — no sleep timing.
      stub(EmailServiceMock, :send_email_verification, fn _user, _url ->
        receive do
          :never -> {:ok, :sent}
        end
      end)

      assert {:discard, "Email sending timed out"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_verification",
                 "user_id" => user.id,
                 "verification_url" => "https://example.com/verify"
               })
    end
  end

  describe "perform/1 — default timeout" do
    @send_deadline_ms 100

    setup do
      setup_config(:tymeslot, email_timeout_ms: nil, email_send_deadline_ms: @send_deadline_ms)
    end

    # A fixed 30 seconds let two stalled sends exhaust the job, which was then
    # discarded before the remaining recipients were emailed. Each send here
    # takes nearly the whole send deadline, so the job only completes if its
    # budget covers every recipient of the largest confirmation.
    test "outlasts a confirmation whose every send takes nearly the full send deadline" do
      meeting = insert(:meeting, organizer_email_sent: false, attendee_email_sent: false)
      guest_emails = for n <- 1..Guests.max_guests(), do: "guest#{n}@example.com"
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, guest_emails)

      slow_send = fn _email, _details ->
        receive do
          :never -> :unreachable
        after
          @send_deadline_ms - 10 -> {:ok, "sent"}
        end
      end

      stub(EmailServiceMock, :send_appointment_confirmation_to_organizer, slow_send)
      stub(EmailServiceMock, :send_appointment_confirmation_to_attendee, slow_send)
      stub(EmailServiceMock, :send_guest_confirmation, slow_send)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_confirmation_emails",
                 "meeting_id" => meeting.id
               })

      {:ok, meeting} = MeetingQueries.get_meeting(meeting.id)
      assert meeting.attendee_email_sent
      assert GuestQueries.list_unsent_for_meeting(meeting.id) == []
    end
  end
end
