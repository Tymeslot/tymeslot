defmodule Tymeslot.Workers.EmailWorkerHandlers.GuestConfirmationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  import Mox
  import Tymeslot.Factory
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  describe "send_guest_confirmations (via send_confirmation_emails)" do
    # Guest confirmations are triggered as a side-effect whenever the attendee
    # confirmation needs sending.  We exercise `send_guest_confirmations/3`
    # indirectly through `execute_email_action/2` so the full handler path
    # (including DB stamp reads and writes) runs end-to-end.

    test "sends one confirmation per unsent guest with correct RSVP URLs" do
      meeting = insert(:meeting, organizer_email_sent: false, attendee_email_sent: false)
      {:ok, [g1, g2]} = Guests.create_for_meeting(meeting.id, ["a@example.com", "b@example.com"])

      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:ok, "sent"}
      end)

      # Expect exactly one send per guest, each with correct accept/decline URLs.
      expect(EmailServiceMock, :send_guest_confirmation, fn "a@example.com", details ->
        expected_urls = Policy.guest_rsvp_urls(g1.rsvp_token)
        assert details.guest_accept_url == expected_urls.accept_url
        assert details.guest_decline_url == expected_urls.decline_url
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_guest_confirmation, fn "b@example.com", details ->
        expected_urls = Policy.guest_rsvp_urls(g2.rsvp_token)
        assert details.guest_accept_url == expected_urls.accept_url
        assert details.guest_decline_url == expected_urls.decline_url
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })

      # Both guests should now be stamped.
      unsent = GuestQueries.list_unsent_for_meeting(meeting.id)
      assert unsent == []
    end

    test "idempotency: already-stamped guests are not re-sent on a second run" do
      meeting = insert(:meeting, organizer_email_sent: false, attendee_email_sent: false)
      {:ok, [g1, _g2]} = Guests.create_for_meeting(meeting.id, ["a@example.com", "b@example.com"])

      # Pre-stamp g1 to simulate a partial previous run.
      {:ok, _guest} = GuestQueries.mark_confirmation_sent(g1, DateTime.utc_now(:second))

      # Organiser/attendee confirmations are still needed on this run.
      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:ok, "sent"}
      end)

      # Only the unsent guest should receive an email; verify_on_exit! enforces
      # that send_guest_confirmation is called exactly once (not twice).
      expect(EmailServiceMock, :send_guest_confirmation, fn "b@example.com", _details ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })

      # Both guests stamped after successful run.
      unsent = GuestQueries.list_unsent_for_meeting(meeting.id)
      assert unsent == []
    end

    test "full idempotency: no guest emails at all when all guests are already stamped" do
      meeting = insert(:meeting, organizer_email_sent: false, attendee_email_sent: false)
      {:ok, [g1, g2]} = Guests.create_for_meeting(meeting.id, ["a@example.com", "b@example.com"])
      now = DateTime.utc_now(:second)
      {:ok, _guest1} = GuestQueries.mark_confirmation_sent(g1, now)
      {:ok, _guest2} = GuestQueries.mark_confirmation_sent(g2, now)

      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:ok, "sent"}
      end)

      # verify_on_exit! will fail the test if send_guest_confirmation is called.
      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })
    end

    test "a guest-send failure is swallowed and does not affect the overall job result" do
      meeting = insert(:meeting, organizer_email_sent: false, attendee_email_sent: false)
      {:ok, [_g1]} = Guests.create_for_meeting(meeting.id, ["a@example.com"])

      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:ok, "sent"}
      end)

      # The guest send fails.
      expect(EmailServiceMock, :send_guest_confirmation, fn "a@example.com", _details ->
        {:error, "smtp timeout"}
      end)

      # The overall job must still return :ok — guest failures must not bubble up.
      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })

      # The guest should NOT be stamped since the send failed.
      unsent = GuestQueries.list_unsent_for_meeting(meeting.id)
      assert length(unsent) == 1
    end

    test "no guest emails are sent when the meeting has no guests" do
      meeting = insert(:meeting, organizer_email_sent: false, attendee_email_sent: false)

      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:ok, "sent"}
      end)

      # verify_on_exit! enforces send_guest_confirmation is never called.
      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })
    end
  end
end
