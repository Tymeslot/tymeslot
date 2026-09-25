defmodule Tymeslot.Workers.EmailWorkerHandlers.GuestReminderTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers
  @moduletag :emails

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  # Guest reminders are sent from inside `send_reminder_emails/3`, so they are
  # exercised through `execute_email_action/2`: that is the only way the guards
  # it inherits, and the per-guest stamp reads and writes, run for real.
  defp upcoming_meeting(attrs \\ %{}) do
    start_time = DateTime.add(DateTime.utc_now(:second), 24, :hour)

    insert(
      :meeting,
      Map.merge(
        %{
          status: "scheduled",
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour)
        },
        attrs
      )
    )
  end

  defp invited_guests(meeting, emails) do
    {:ok, guests} = Guests.create_for_meeting(meeting.id, emails)
    now = DateTime.utc_now(:second)

    Enum.map(guests, fn guest ->
      {:ok, stamped} = GuestQueries.mark_confirmation_sent(guest, now)
      stamped
    end)
  end

  defp expect_participant_reminders do
    expect(EmailServiceMock, :send_appointment_reminder_to_organizer, fn _email, _details ->
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_appointment_reminder_to_attendee, fn _email, _details ->
      {:ok, "sent"}
    end)
  end

  defp run_reminder(meeting, value \\ 24, unit \\ "hours") do
    EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{
      "meeting_id" => meeting.id,
      "reminder_value" => value,
      "reminder_unit" => unit
    })
  end

  describe "guest reminders" do
    test "sends one reminder per invited guest, carrying their own RSVP links" do
      meeting = upcoming_meeting()
      [g1, g2] = invited_guests(meeting, ["a@example.com", "b@example.com"])

      expect_participant_reminders()

      expect(EmailServiceMock, :send_guest_reminder, fn "a@example.com", details ->
        assert details.guest_accept_url == Policy.guest_rsvp_urls(g1.rsvp_token).accept_url
        assert details.guest_decline_url == Policy.guest_rsvp_urls(g1.rsvp_token).decline_url
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_guest_reminder, fn "b@example.com", details ->
        assert details.guest_accept_url == Policy.guest_rsvp_urls(g2.rsvp_token).accept_url
        {:ok, "sent"}
      end)

      run_reminder(meeting)

      # Both guests are now stamped for this offset, and for no other.
      assert GuestQueries.list_for_reminder(meeting.id, 24, "hours") == []
      assert length(GuestQueries.list_for_reminder(meeting.id, 1, "hours")) == 2
    end

    test "a second run for the same offset re-emails nobody" do
      meeting = upcoming_meeting()
      invited_guests(meeting, ["a@example.com"])

      expect_participant_reminders()

      expect(EmailServiceMock, :send_guest_reminder, fn "a@example.com", _details ->
        {:ok, "s"}
      end)

      run_reminder(meeting)

      # The meeting's own reminder state is what stops the participant emails
      # on the second run; verify_on_exit! fails the test if the guest is
      # emailed again.
      run_reminder(meeting)

      [guest] = GuestQueries.list_for_meeting(meeting.id)
      assert length(guest.reminders_sent) == 1
    end

    test "each configured offset reminds the guest once" do
      meeting = upcoming_meeting()
      invited_guests(meeting, ["a@example.com"])

      expect_participant_reminders()

      expect(EmailServiceMock, :send_guest_reminder, fn "a@example.com", _details ->
        {:ok, "s"}
      end)

      run_reminder(meeting, 24, "hours")

      expect_participant_reminders()

      expect(EmailServiceMock, :send_guest_reminder, fn "a@example.com", _details ->
        {:ok, "s"}
      end)

      run_reminder(meeting, 1, "hours")

      assert GuestQueries.list_for_reminder(meeting.id, 24, "hours") == []
      assert GuestQueries.list_for_reminder(meeting.id, 1, "hours") == []
    end

    test "a guest who declined is not chased: the time has not changed" do
      meeting = upcoming_meeting()
      [declined, attending] = invited_guests(meeting, ["no@example.com", "yes@example.com"])

      {:ok, _guest} =
        GuestQueries.update_rsvp(declined, %{
          status: "declined",
          responded_at: DateTime.utc_now(:second)
        })

      expect_participant_reminders()

      # verify_on_exit! fails the test if the declined guest is emailed.
      expect(EmailServiceMock, :send_guest_reminder, fn email, _details ->
        assert email == attending.email
        {:ok, "sent"}
      end)

      run_reminder(meeting)
    end

    test "a guest who was never invited gets no reminder" do
      meeting = upcoming_meeting()
      {:ok, [_uninvited]} = Guests.create_for_meeting(meeting.id, ["a@example.com"])

      expect_participant_reminders()

      # No confirmation was ever sent to this guest, so there is nothing to
      # remind them of; verify_on_exit! fails the test if one goes out.
      run_reminder(meeting)
    end

    test "a failed guest send leaves that guest unstamped and the job unaffected" do
      meeting = upcoming_meeting()
      invited_guests(meeting, ["a@example.com"])

      expect_participant_reminders()

      expect(EmailServiceMock, :send_guest_reminder, fn "a@example.com", _details ->
        {:error, "smtp timeout"}
      end)

      run_reminder(meeting)

      # Unstamped, so the retry that follows will reach them.
      assert [%{email: "a@example.com"}] = GuestQueries.list_for_reminder(meeting.id, 24, "hours")
    end

    test "a meeting that has already started reminds nobody, guests included" do
      started =
        upcoming_meeting(%{
          start_time: DateTime.add(DateTime.utc_now(:second), -1, :hour),
          end_time: DateTime.add(DateTime.utc_now(:second), 1, :hour)
        })

      invited_guests(started, ["a@example.com"])

      # The guard lives in the handler above the send, so no email of any kind
      # goes out; verify_on_exit! fails the test if one does.
      run_reminder(started)

      assert [%{email: "a@example.com"}] = GuestQueries.list_for_reminder(started.id, 24, "hours")
    end
  end
end
