defmodule Tymeslot.InviteeData.HeldBookingsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.InviteeData
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema

  @email "ada@example.com"

  describe "erasing an invitee with a booking held for email confirmation" do
    test "erases the booking without naming it, releasing the hold" do
      held = insert(:awaiting_verification_meeting, attendee_email: @email)

      assert {:ok, %{meetings: 1}} = InviteeData.erase(@email)

      released = Repo.get!(MeetingSchema, held.id)
      assert %{status: :cancelled, attendee_email: nil} = released
      assert {:error, :expired} = EmailVerification.verify(released)
    end

    test "a host-scoped erasure is not blocked by it either" do
      host = insert(:user)
      held = insert(:awaiting_verification_meeting, organizer_user: host, attendee_email: @email)

      assert {:ok, %{meetings: 1}} = InviteeData.erase_for_host(host.id, @email)
      assert %{status: :cancelled} = Repo.get!(MeetingSchema, held.id)
    end

    test "is not blocked by a guest invitation on the held booking" do
      held = insert(:awaiting_verification_meeting)

      {:ok, guest} =
        GuestQueries.insert_guest(%{
          meeting_id: held.id,
          email: "guest@example.com",
          name: "A Guest"
        })

      assert {:ok, %{guests: 1}} = InviteeData.erase("guest@example.com")
      assert %{status: :awaiting_verification} = Repo.get!(MeetingSchema, held.id)
      assert %{email: "erased-" <> _rest} = Repo.get!(GuestSchema, guest.id)
    end
  end
end
