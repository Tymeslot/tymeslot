defmodule Tymeslot.Workers.EmailWorkerHandlers.GuestInvitationTest do
  @moduledoc """
  Guests a host adds after the booking was made are invited, and the guests who
  were already there are not written to a second time.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :workers

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  describe "send_guest_invitations" do
    test "invites the guest just added and leaves the invited ones alone" do
      meeting = insert(:meeting, organizer_email_sent: true, attendee_email_sent: true)
      {:ok, [early]} = Guests.create_for_meeting(meeting.id, ["early@example.com"])
      {:ok, _stamped} = GuestQueries.mark_confirmation_sent(early, DateTime.utc_now(:second))

      {:ok, [_late]} =
        Guests.add_to_meeting(meeting.id, ["late@example.com"], meeting.attendee_email)

      # `verify_on_exit!` fails the test if a second send is attempted, so this
      # single expectation is what proves the early guest is left alone.
      expect(EmailServiceMock, :send_guest_confirmation, fn "late@example.com", _details ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_guest_invitations", %{
                 "meeting_id" => meeting.id
               })

      assert GuestQueries.list_unsent_for_meeting(meeting.id) == []
    end

    test "sends nothing when every guest has already been invited" do
      meeting = insert(:meeting, organizer_email_sent: true, attendee_email_sent: true)
      {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
      {:ok, _stamped} = GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_guest_invitations", %{
                 "meeting_id" => meeting.id
               })
    end

    test "does not touch the organiser's or the attendee's own confirmations" do
      meeting = insert(:meeting, organizer_email_sent: true, attendee_email_sent: true)

      {:ok, [_guest]} =
        Guests.add_to_meeting(meeting.id, ["guest@example.com"], meeting.attendee_email)

      expect(EmailServiceMock, :send_guest_confirmation, fn "guest@example.com", _details ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_guest_invitations", %{
                 "meeting_id" => meeting.id
               })

      reloaded = Repo.get(Tymeslot.Meetings.MeetingSchema, meeting.id)
      assert reloaded.organizer_email_sent
      assert reloaded.attendee_email_sent
    end
  end
end
