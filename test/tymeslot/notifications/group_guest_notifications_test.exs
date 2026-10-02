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

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.EmailWorkerHandlers.GuestEmails

  setup :verify_on_exit!

  setup do
    # A group meeting is confirmed from its first seat and never goes through
    # the booking's announcement claim, so it carries no `first_announced_at`.
    organizer = insert(:user)
    insert(:profile, user: organizer, timezone: "Europe/London")

    meeting =
      insert(:group_meeting,
        capacity: 4,
        first_announced_at: nil,
        organizer_user_id: organizer.id,
        attendee_locale: "en"
      )

    # A guest's emails follow the participant who invited them, not the slot
    # row (whose locale is the first booker's and which has no timezone).
    staying =
      insert(:participant,
        meeting: meeting,
        name: "Staying Booker",
        locale: "uk",
        timezone: "Asia/Tokyo"
      )

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

    %{meeting: meeting, staying: staying, staying_guest: staying_guest, left_guest: left_guest}
  end

  describe "cancelling the whole meeting" do
    test "tells the guests of seats still held, in their own participant's view", %{
      meeting: meeting,
      staying: staying
    } do
      test_pid = self()

      expect(EmailServiceMock, :send_guest_cancellation, fn email, details ->
        send(test_pid, {:guest_cancellation, email, details})
        {:ok, :sent}
      end)

      assert :ok =
               GuestNotifications.notify_cancelled(
                 meeting,
                 AppointmentBuilder.from_meeting(meeting)
               )

      assert_received {:guest_cancellation, "stays@example.com", details}
      refute_received {:guest_cancellation, "left@example.com", _details}

      assert details.attendee_name == "Staying Booker"
      assert details.attendee_locale == "uk"
      assert details.attendee_timezone == "Asia/Tokyo"
      assert details.uid == staying.id
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

    test "are in the inviting participant's language and timezone, on their seat's entry", %{
      meeting: meeting,
      staying: staying
    } do
      test_pid = self()

      expect(EmailServiceMock, :send_guest_reminder, fn email, details ->
        send(test_pid, {:guest_reminder, email, details})
        {:ok, :sent}
      end)

      reminder = %{value: 30, unit: "minutes"}

      assert :ok =
               GuestEmails.send_reminders(
                 meeting,
                 AppointmentBuilder.from_meeting(meeting, reminder),
                 30,
                 "minutes"
               )

      assert_received {:guest_reminder, "stays@example.com", details}
      assert details.attendee_locale == "uk"
      assert details.attendee_timezone == "Asia/Tokyo"
      assert details.uid == staying.id
    end
  end
end
