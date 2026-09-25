defmodule Tymeslot.Notifications.GroupGuestNotificationsTest do
  @moduledoc """
  What a group meeting's guests are told after they were invited.

  On a group meeting a guest belongs to the participant who brought them.
  Cancelling or moving that seat voids the guest's invitation while the
  meeting carries on, so the guest must hear nothing more about it; a guest
  whose participant still holds their seat is told like any other, and is
  told who invited them.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :notifications
  @moduletag :meetings

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.GuestNotifications

  setup :verify_on_exit!

  setup do
    # A group meeting is confirmed from its first seat and never goes through
    # the booking's announcement claim, so it carries no `first_announced_at`.
    meeting = insert(:group_meeting, capacity: 4, first_announced_at: nil)

    staying = insert(:participant, meeting: meeting, name: "Staying Booker")

    left =
      insert(:participant,
        meeting: meeting,
        name: "Departed Booker",
        cancelled_at: DateTime.utc_now(:second)
      )

    {:ok, [staying_guest]} =
      Guests.create_for_participant(meeting.id, staying.id, ["stays@example.com"])

    {:ok, [left_guest]} =
      Guests.create_for_participant(meeting.id, left.id, ["left@example.com"])

    for guest <- [staying_guest, left_guest] do
      {:ok, _guest} = GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))
    end

    %{meeting: meeting, staying_guest: staying_guest, left_guest: left_guest}
  end

  describe "cancelling the whole meeting" do
    test "tells the guests of seats still held, naming their own participant", %{
      meeting: meeting
    } do
      test_pid = self()

      expect(EmailServiceMock, :send_guest_cancellation, fn email, details ->
        send(test_pid, {:guest_cancellation, email, details.attendee_name})
        {:ok, :sent}
      end)

      assert :ok =
               GuestNotifications.notify_cancelled(meeting, %{
                 organizer_name: "Host",
                 attendee_name: nil
               })

      assert_received {:guest_cancellation, "stays@example.com", "Staying Booker"}
      refute_received {:guest_cancellation, "left@example.com", _booker}
    end
  end

  describe "reminders" do
    test "go only to the guests of seats still held", %{
      meeting: meeting,
      staying_guest: staying_guest
    } do
      assert [guest] = GuestQueries.list_for_reminder(meeting.id, 30, "minutes")
      assert guest.id == staying_guest.id
    end
  end
end
