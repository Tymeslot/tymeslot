defmodule Tymeslot.Notifications.GuestNotificationsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :notifications

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  defp meeting_with_guests(attrs \\ %{}) do
    meeting =
      insert(
        :meeting,
        Map.merge(%{first_announced_at: DateTime.utc_now(:second), status: "confirmed"}, attrs)
      )

    {:ok, [accepted, declined]} =
      Guests.create_for_meeting(meeting.id, ["yes@example.com", "no@example.com"])

    # Written directly: the meeting is often in a state (cancelled, awaiting
    # approval) that no longer takes responses, but the guests answered while
    # it still did.
    {:ok, _guest} = GuestQueries.update_rsvp(accepted, %{status: "accepted"})
    {:ok, _guest} = GuestQueries.update_rsvp(declined, %{status: "declined"})

    for guest <- [accepted, declined] do
      {:ok, _guest} = GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))
    end

    %{meeting: meeting, accepted: accepted, declined: declined}
  end

  describe "reset_for_new_time/1, then notify_rescheduled/3" do
    test "resets every answer and asks every guest again, declined ones included" do
      %{meeting: meeting, accepted: accepted, declined: declined} = meeting_with_guests()

      test_pid = self()

      expect(EmailServiceMock, :send_guest_reschedule, 2, fn email, details ->
        send(test_pid, {:guest_reschedule, email, details.guest_accept_url})
        {:ok, :sent}
      end)

      assert :ok = GuestNotifications.reset_for_new_time(meeting)
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
            do: {guest.email, MeetingLinks.guest_rsvp_urls(guest.rsvp_token).accept_url}

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

    test "every guest is tried, and the failures are reported" do
      %{meeting: meeting} = meeting_with_guests()

      expect(EmailServiceMock, :send_guest_reschedule, 2, fn _email, _details ->
        {:error, :smtp_down}
      end)

      assert {:error, {:guest_emails_failed, 2}} =
               GuestNotifications.notify_rescheduled(meeting, %{})
    end
  end

  describe "a mail outage partway through the guests" do
    defp moved(attrs \\ %{}) do
      start_time = DateTime.add(DateTime.utc_now(:second), 3, :day)

      Map.merge(
        %{start_time: start_time, end_time: DateTime.add(start_time, 30, :minute)},
        attrs
      )
    end

    # Runs the job as Oban would, keeping its id, so the per-recipient claims
    # carry over from one run to the next.
    defp run_job(action) do
      [job] = all_enqueued(worker: EmailWorker, args: %{"action" => action})
      EmailWorker.perform(%{job | attempt: job.attempt + 1})
    end

    # The send runs in the job's own process, so the one-shot flag is an
    # atomic shared with it rather than this process's dictionary.
    defp fail_once_for(address, fun) do
      test_pid = self()
      failed = :atomics.new(1, [])

      stub(EmailServiceMock, fun, fn email, _details ->
        send(test_pid, {:guest_send, email})

        if email == address and :atomics.compare_exchange(failed, 1, 0, 1) == :ok,
          do: {:error, :smtp_down},
          else: {:ok, :sent}
      end)
    end

    test "the reschedule job retries, and the retry writes only to the guest missed" do
      %{meeting: meeting} = meeting_with_guests(moved())

      expect(EmailServiceMock, :send_reschedule_email_to_organizer, 1, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_reschedule_email_to_attendee, 1, fn _email, _details ->
        {:ok, :sent}
      end)

      fail_once_for("no@example.com", :send_guest_reschedule)

      :ok =
        EmailScheduler.schedule_reschedule_emails(meeting, %{
          start_time: DateTime.add(meeting.start_time, -1, :day),
          end_time: DateTime.add(meeting.end_time, -1, :day)
        })

      assert {:error, "1 guest email(s) failed"} = run_job("send_reschedule_emails")
      assert_received {:guest_send, "yes@example.com"}
      assert_received {:guest_send, "no@example.com"}

      assert :ok = run_job("send_reschedule_emails")
      assert_received {:guest_send, "no@example.com"}
      refute_received {:guest_send, _email}
    end

    test "the cancellation job retries, and the retry writes only to the guest missed" do
      %{meeting: meeting} = meeting_with_guests(moved(%{status: "cancelled"}))

      expect(EmailServiceMock, :send_cancellation_email_to_organizer, 1, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_cancellation_email_to_attendee, 1, fn _email, _details ->
        {:ok, :sent}
      end)

      fail_once_for("yes@example.com", :send_guest_cancellation)

      :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)

      assert {:error, "1 guest email(s) failed"} = run_job("send_cancellation_emails")
      assert_received {:guest_send, "yes@example.com"}
      assert_received {:guest_send, "no@example.com"}

      assert :ok = run_job("send_cancellation_emails")
      assert_received {:guest_send, "yes@example.com"}
      refute_received {:guest_send, _email}
    end
  end

  # An attendee whose address the provider suppressed must not cost the
  # guests their retry: every copy is attempted, and a failure a retry can
  # fix outweighs the rejection.
  describe "a rejected attendee alongside a guest that failed" do
    @rejected {:error, {:recipient_rejected, {422, %{"ErrorCode" => 406}}}}

    for {notice, action, guest_fun, organizer_fun, attendee_fun} <- [
          {"reschedule", "send_reschedule_emails", :send_guest_reschedule,
           :send_reschedule_email_to_organizer, :send_reschedule_email_to_attendee},
          {"cancellation", "send_cancellation_emails", :send_guest_cancellation,
           :send_cancellation_email_to_organizer, :send_cancellation_email_to_attendee}
        ] do
      test "the #{notice} job retries for the guest, and then gives up on the attendee alone" do
        start_time = DateTime.add(DateTime.utc_now(:second), 3, :day)
        status = if unquote(notice) == "cancellation", do: "cancelled", else: "confirmed"

        %{meeting: meeting} =
          meeting_with_guests(%{
            start_time: start_time,
            end_time: DateTime.add(start_time, 30, :minute),
            status: status
          })

        expect(EmailServiceMock, unquote(organizer_fun), 1, fn _email, _details ->
          {:ok, :sent}
        end)

        expect(EmailServiceMock, unquote(attendee_fun), 2, fn _email, _details -> @rejected end)
        fail_guest_once("yes@example.com", unquote(guest_fun))

        schedule(unquote(notice), meeting)

        assert {:error, reason} = run_queued(unquote(action))
        refute match?({:recipient_rejected, _rejection}, reason)

        # The retry reaches the guest it missed; only the rejected attendee is
        # left, which no retry can help.
        assert {:discard, _reason} = run_queued(unquote(action))
        assert_received {:guest_send, "yes@example.com"}
        assert_received {:guest_send, "no@example.com"}
        assert_received {:guest_send, "yes@example.com"}
        refute_received {:guest_send, _email}
      end
    end

    defp schedule("reschedule", meeting) do
      :ok =
        EmailScheduler.schedule_reschedule_emails(meeting, %{
          start_time: DateTime.add(meeting.start_time, -1, :day),
          end_time: DateTime.add(meeting.end_time, -1, :day)
        })
    end

    defp schedule("cancellation", meeting),
      do: :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)

    defp run_queued(action) do
      [job] = all_enqueued(worker: EmailWorker, args: %{"action" => action})
      EmailWorker.perform(%{job | attempt: job.attempt + 1})
    end

    defp fail_guest_once(address, fun) do
      test_pid = self()
      failed = :atomics.new(1, [])

      stub(EmailServiceMock, fun, fn email, _details ->
        send(test_pid, {:guest_send, email})

        if email == address and :atomics.compare_exchange(failed, 1, 0, 1) == :ok,
          do: {:error, :smtp_down},
          else: {:ok, :sent}
      end)
    end
  end

  describe "reset_for_new_time/1" do
    test "resets the answers without emailing anyone" do
      %{meeting: meeting} = meeting_with_guests()

      assert :ok = GuestNotifications.reset_for_new_time(meeting)

      assert Enum.all?(GuestQueries.list_for_meeting(meeting.id), &(&1.status == "pending"))
      # Still on record as invited: approval tells them about the move.
      assert GuestQueries.list_unsent_for_meeting(meeting.id) == []
    end
  end

  describe "notify_reapproved/3 (via Approval.approve/1 and the reschedule email job)" do
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
      GuestNotifications.reset_for_new_time(meeting)

      expect(EmailServiceMock, :send_reschedule_email_to_organizer, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_reschedule_email_to_attendee, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_guest_reschedule, 2, fn _email, details ->
        assert details.guest_accept_url
        {:ok, :sent}
      end)

      assert {:ok, _confirmed} = Approval.approve(meeting)
      run_reschedule_emails()
    end

    test "approving a first request leaves its guests to the confirmation invitation" do
      meeting = insert(:meeting, held(%{first_announced_at: nil}))
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["new@example.com"])

      # verify_on_exit! fails the test if a reschedule email is sent.
      assert {:ok, _confirmed} = Approval.approve(meeting)
      run_reschedule_emails()
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

      expect(EmailServiceMock, :send_cancellation_email_to_organizer, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_cancellation_email_to_attendee, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_guest_cancellation, 2, fn _email, _details ->
        {:ok, :sent}
      end)

      assert :ok =
               EmailHandlers.execute_email_action("send_cancellation_emails", %{
                 "meeting_id" => meeting.id
               })
    end
  end

  defp run_reschedule_emails do
    for job <- all_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_emails"}),
        do: perform_job(EmailWorker, job.args)
  end
end
