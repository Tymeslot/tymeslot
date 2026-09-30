defmodule Tymeslot.Workers.EmailWorkerHandlers.GuestInvitationTest do
  @moduledoc """
  Guests a host adds after the booking was made are invited, and the guests who
  were already there are not written to a second time.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :workers
  @moduletag :emails

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  defp run(meeting, guests) do
    EmailWorkerHandlers.execute_email_action("send_guest_invitations", %{
      "meeting_id" => meeting.id,
      "guest_ids" => Enum.map(guests, & &1.id)
    })
  end

  defp confirmed_meeting(attrs \\ []) do
    insert(:meeting, [organizer_email_sent: true, attendee_email_sent: true] ++ attrs)
  end

  describe "send_guest_invitations" do
    test "invites the guests the job names and leaves the invited ones alone" do
      meeting = confirmed_meeting()
      {:ok, [early]} = Guests.create_for_meeting(meeting.id, ["early@example.com"])
      {:ok, _stamped} = GuestQueries.mark_confirmation_sent(early, DateTime.utc_now(:second))
      {:ok, late} = Guests.create_for_meeting(meeting.id, ["late@example.com"])

      # `verify_on_exit!` fails the test if a second send is attempted, so this
      # single expectation is what proves the early guest is left alone.
      expect(EmailServiceMock, :send_guest_confirmation, fn "late@example.com", _details ->
        {:ok, "sent"}
      end)

      assert :ok = run(meeting, late)
      assert GuestQueries.list_unsent_for_meeting(meeting.id) == []
    end

    test "does not send to an unsent guest another job is responsible for" do
      meeting = confirmed_meeting()
      {:ok, [mine]} = Guests.create_for_meeting(meeting.id, ["mine@example.com"])
      {:ok, [_theirs]} = Guests.create_for_meeting(meeting.id, ["theirs@example.com"])

      expect(EmailServiceMock, :send_guest_confirmation, fn "mine@example.com", _details ->
        {:ok, "sent"}
      end)

      assert :ok = run(meeting, [mine])

      assert [%{email: "theirs@example.com"}] =
               GuestQueries.list_unsent_for_meeting(meeting.id)
    end

    test "fails a send so Oban retries it, and the retry reaches only the guest it missed" do
      meeting = confirmed_meeting()

      {:ok, guests} =
        Guests.create_for_meeting(meeting.id, ["ok@example.com", "flaky@example.com"])

      expect(EmailServiceMock, :send_guest_confirmation, 2, fn
        "ok@example.com", _details -> {:ok, "sent"}
        "flaky@example.com", _details -> {:error, :timeout}
      end)

      assert {:error, _reason} = run(meeting, guests)

      assert [%{email: "flaky@example.com"}] =
               GuestQueries.list_unsent_for_meeting(meeting.id)

      expect(EmailServiceMock, :send_guest_confirmation, fn "flaky@example.com", _details ->
        {:ok, "sent"}
      end)

      assert :ok = run(meeting, guests)
      assert GuestQueries.list_unsent_for_meeting(meeting.id) == []
    end

    test "does not retry a guest the provider rejected outright" do
      meeting = confirmed_meeting()
      {:ok, guests} = Guests.create_for_meeting(meeting.id, ["dead@example.com"])

      expect(EmailServiceMock, :send_guest_confirmation, fn "dead@example.com", _details ->
        {:error, {:recipient_rejected, "550 no such user"}}
      end)

      assert :ok = run(meeting, guests)
    end

    test "discards the job for a meeting cancelled since the guests were added" do
      meeting = confirmed_meeting(status: "cancelled")
      {:ok, guests} = Guests.create_for_meeting(meeting.id, ["late@example.com"])

      # No expectation: any send fails the test.
      assert {:discard, reason} = run(meeting, guests)
      assert EmailWorkerHandlers.expected_discard?(reason)
      assert [%{email: "late@example.com"}] = GuestQueries.list_unsent_for_meeting(meeting.id)
    end

    test "discards the job for a meeting that has started" do
      now = DateTime.utc_now(:second)

      meeting =
        confirmed_meeting(
          start_time: DateTime.add(now, -5, :minute),
          end_time: DateTime.add(now, 55, :minute)
        )

      {:ok, guests} = Guests.create_for_meeting(meeting.id, ["late@example.com"])

      assert {:discard, _reason} = run(meeting, guests)
    end

    test "does not touch the organiser's or the attendee's own confirmations" do
      meeting = confirmed_meeting()
      {:ok, guests} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])

      expect(EmailServiceMock, :send_guest_confirmation, fn "guest@example.com", _details ->
        {:ok, "sent"}
      end)

      assert :ok = run(meeting, guests)

      reloaded = Repo.get(Tymeslot.Meetings.MeetingSchema, meeting.id)
      assert reloaded.organizer_email_sent
      assert reloaded.attendee_email_sent
    end
  end

  describe "a guest added while the booking's confirmation is still going out" do
    # The confirmation job lists every unsent guest, and the host's invitation
    # job names the guest it added; both can hold the same guest at once. The
    # invitation job is run from inside the confirmation's first guest send,
    # which is the moment the two jobs overlap: the confirmation has already
    # listed the late guest as unsent, and has not reached them yet.
    test "is invited once, by whichever job claims them first" do
      meeting = insert(:meeting, organizer_email_sent: false, attendee_email_sent: false)
      {:ok, [_booked]} = Guests.create_for_meeting(meeting.id, ["a-booked@example.com"])
      {:ok, [late]} = Guests.create_for_meeting(meeting.id, ["late@example.com"], :organizer)

      stub(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _to, _details ->
        {:ok, "sent"}
      end)

      stub(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _to, _details ->
        {:ok, "sent"}
      end)

      test_pid = self()

      stub(EmailServiceMock, :send_guest_confirmation, fn
        "a-booked@example.com", _details ->
          send(test_pid, {:invitation_job, run(meeting, [late])})
          send(test_pid, {:guest_sent, "a-booked@example.com"})
          {:ok, "sent"}

        email, _details ->
          send(test_pid, {:guest_sent, email})
          {:ok, "sent"}
      end)

      EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
        "meeting_id" => meeting.id
      })

      assert_received {:invitation_job, :ok}
      assert_received {:guest_sent, "a-booked@example.com"}
      assert_received {:guest_sent, "late@example.com"}
      refute_received {:guest_sent, "late@example.com"}
      assert GuestQueries.list_unsent_for_meeting(meeting.id) == []
    end
  end
end
