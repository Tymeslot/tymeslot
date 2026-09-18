defmodule Tymeslot.Notifications.GuestNotificationsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :notifications

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  defp meeting_with_guests(attrs \\ %{}) do
    meeting =
      insert(
        :meeting,
        Map.merge(%{first_announced_at: DateTime.utc_now(:second), status: "confirmed"}, attrs)
      )

    {:ok, [accepted, declined]} =
      Guests.create_for_meeting(meeting.id, ["yes@example.com", "no@example.com"])

    {:ok, _guest} = Guests.record_rsvp(accepted.rsvp_token, "accepted")
    {:ok, _guest} = Guests.record_rsvp(declined.rsvp_token, "declined")

    for guest <- [accepted, declined] do
      {:ok, _guest} = GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))
    end

    %{meeting: meeting, accepted: accepted, declined: declined}
  end

  describe "notify_rescheduled/2" do
    test "resets every answer and asks every guest again, declined ones included" do
      %{meeting: meeting, accepted: accepted, declined: declined} = meeting_with_guests()

      test_pid = self()

      expect(EmailServiceMock, :send_guest_reschedule, 2, fn email, details ->
        send(test_pid, {:guest_reschedule, email, details.guest_accept_url})
        {:ok, :sent}
      end)

      assert :ok = GuestNotifications.notify_rescheduled(meeting, %{uid: meeting.uid})

      # Guests are loaded without an order, so compare the set of emails sent
      # rather than the sequence.
      sent =
        for _guest <- 1..2 do
          assert_received {:guest_reschedule, email, accept_url}
          {email, accept_url}
        end

      expected =
        for guest <- [accepted, declined],
            do: {guest.email, Policy.guest_rsvp_urls(guest.rsvp_token).accept_url}

      assert Enum.sort(sent) == Enum.sort(expected)

      guests = GuestQueries.list_for_meeting(meeting.id)
      assert Enum.all?(guests, &(&1.status == "pending" and is_nil(&1.responded_at)))
      # They were invited before; that stays on record.
      assert GuestQueries.list_unsent_for_meeting(meeting.id) == []
    end

    test "sends nothing for a booking without guests" do
      meeting = insert(:meeting)
      assert :ok = GuestNotifications.notify_rescheduled(meeting, %{})
    end

    test "a failed send does not fail the reschedule" do
      %{meeting: meeting} = meeting_with_guests()

      expect(EmailServiceMock, :send_guest_reschedule, 2, fn _email, _details ->
        {:error, :smtp_down}
      end)

      assert :ok = GuestNotifications.notify_rescheduled(meeting, %{})
    end
  end

  describe "prepare_for_reapproval/1" do
    test "resets the answers without emailing anyone" do
      %{meeting: meeting} = meeting_with_guests()

      assert :ok = GuestNotifications.prepare_for_reapproval(meeting)

      assert Enum.all?(GuestQueries.list_for_meeting(meeting.id), &(&1.status == "pending"))
      # Still on record as invited: approval tells them about the move.
      assert GuestQueries.list_unsent_for_meeting(meeting.id) == []
    end
  end

  describe "notify_reapproved/1 (via Approval.approve/1)" do
    defp held(attrs) do
      user = insert(:user)

      Map.merge(
        %{
          status: "awaiting_approval",
          organizer_user_id: user.id,
          approval_requested_at: DateTime.utc_now(:second),
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour),
          start_time: DateTime.add(DateTime.utc_now(:second), 3, :day),
          end_time: DateTime.add(DateTime.utc_now(:second), 3 * 86_400 + 1_800, :second)
        },
        attrs
      )
    end

    test "approving a rescheduled booking sends its invited guests the reschedule email" do
      %{meeting: meeting} = meeting_with_guests(held(%{}))
      GuestNotifications.prepare_for_reapproval(meeting)

      expect(EmailServiceMock, :send_guest_reschedule, 2, fn _email, details ->
        assert details.guest_accept_url
        {:ok, :sent}
      end)

      assert {:ok, _confirmed} = Approval.approve(meeting)
    end

    test "approving a first request leaves its guests to the confirmation invitation" do
      meeting = insert(:meeting, held(%{first_announced_at: nil}))
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["new@example.com"])

      # verify_on_exit! fails the test if a reschedule email is sent.
      assert {:ok, _confirmed} = Approval.approve(meeting)
      assert length(GuestQueries.list_unsent_for_meeting(meeting.id)) == 1
    end
  end

  describe "notify_cancelled/2" do
    test "tells every guest of a booking that was confirmed" do
      %{meeting: meeting} = meeting_with_guests()

      expect(EmailServiceMock, :send_guest_cancellation, 2, fn _email, details ->
        assert details.guest_name
        {:ok, :sent}
      end)

      assert :ok = GuestNotifications.notify_cancelled(meeting, %{uid: meeting.uid})
    end

    test "stays silent for a request that was never approved" do
      %{meeting: meeting} = meeting_with_guests(%{first_announced_at: nil})

      assert :ok = GuestNotifications.notify_cancelled(meeting, %{uid: meeting.uid})
    end

    test "declining a rescheduled request that had been confirmed tells the guests" do
      user = insert(:user)

      %{meeting: meeting} =
        meeting_with_guests(%{
          status: "awaiting_approval",
          organizer_user_id: user.id,
          approval_requested_at: DateTime.utc_now(:second),
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
        })

      expect(EmailServiceMock, :send_guest_cancellation, 2, fn _email, _details ->
        {:ok, :sent}
      end)

      assert {:ok, _declined} = Approval.decline(meeting)
    end

    test "declining a request that was never confirmed leaves the guests alone" do
      user = insert(:user)

      %{meeting: meeting} =
        meeting_with_guests(%{
          status: "awaiting_approval",
          first_announced_at: nil,
          organizer_user_id: user.id,
          approval_requested_at: DateTime.utc_now(:second),
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
        })

      assert {:ok, _declined} = Approval.decline(meeting)
    end

    test "the cancellation email job tells the guests alongside host and booker" do
      %{meeting: meeting} = meeting_with_guests(%{status: "cancelled"})

      expect(EmailServiceMock, :send_cancellation_emails, fn _details ->
        {{:ok, :sent}, {:ok, :sent}}
      end)

      expect(EmailServiceMock, :send_guest_cancellation, 2, fn _email, _details ->
        {:ok, :sent}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_cancellation_emails", %{
                 "meeting_id" => meeting.id
               })
    end
  end
end
