defmodule Tymeslot.Notifications.Email.LegacyQueuedJobsTest do
  @moduledoc """
  Jobs queued by the code before the per-recipient claims still run once,
  and only once, after the deploy: a booking request follow-up carrying a
  skip flag sends only the leg it names, and a reschedule or cancellation
  job already holding the pair's "<notice>:participants" claim sends no
  participant copy again. Each job is drained as Oban runs it, then run
  again, and nothing more goes out.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  @moduletag :notifications
  @moduletag :emails

  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    test_pid = self()

    for fun <- [
          :send_reschedule_email_to_organizer,
          :send_reschedule_email_to_attendee,
          :send_cancellation_email_to_organizer,
          :send_cancellation_email_to_attendee
        ] do
      stub(Tymeslot.EmailServiceMock, fun, fn _email, _details ->
        send(test_pid, {:sent, fun})
        {:ok, :sent}
      end)
    end

    stub(Tymeslot.EmailServiceMock, :send_booking_request_received, fn _meeting ->
      send(test_pid, {:sent, :invitee})
      {:ok, :sent}
    end)

    stub(Tymeslot.EmailServiceMock, :send_booking_approval_request, fn _variant,
                                                                       _meeting,
                                                                       _urls,
                                                                       _locale ->
      send(test_pid, {:sent, :host})
      {:ok, :sent}
    end)

    :ok
  end

  describe "a booking request follow-up queued with a skip flag" do
    for {flag, leg} <- [{"skip_host_request", :invitee}, {"skip_attendee_ack", :host}] do
      test "#{flag} sends only the #{leg} leg, once" do
        meeting = held_meeting()

        job =
          insert_job(%{
            "action" => "send_booking_request_emails",
            "meeting_id" => meeting.id,
            unquote(flag) => true
          })

        assert %{success: 1} = Oban.drain_queue(queue: :emails)
        assert_received {:sent, unquote(leg)}
        refute_received {:sent, _other}

        assert :ok = rerun(job)
        refute_received {:sent, _again}
      end
    end
  end

  describe "a job already holding the pair's participants claim" do
    for {notice, action, status} <- [
          {"reschedule", "send_reschedule_emails", "confirmed"},
          {"cancellation", "send_cancellation_emails", "cancelled"}
        ] do
      test "the #{notice} job tells the guest once and no participant again" do
        meeting = announced_meeting(unquote(status))
        guest_sends = guest_sender(unquote(notice))
        job = insert_job(job_args(unquote(action), meeting))
        :ok = DeliveryClaims.once(job.id, "#{unquote(notice)}:participants", fn -> :ok end)

        assert %{success: 1} = Oban.drain_queue(queue: :emails)
        assert_received {:guest, "guest@example.com"}
        refute_received {:sent, _participant}

        assert :ok = rerun(job)
        refute_received {:guest, _again}
        refute_received {:sent, _participant}
        assert :atomics.get(guest_sends, 1) == 1
      end

      test "the #{notice} job whose guest failed retries the guest alone, once" do
        meeting = announced_meeting(unquote(status))
        guest_sends = guest_sender(unquote(notice), fail_first: true)
        job = insert_job(job_args(unquote(action), meeting))
        :ok = DeliveryClaims.once(job.id, "#{unquote(notice)}:participants", fn -> :ok end)

        assert %{failure: 1} = Oban.drain_queue(queue: :emails)
        assert %{success: 1} = Oban.drain_queue(queue: :emails, with_scheduled: true)

        assert :ok = rerun(job)
        refute_received {:sent, _participant}
        assert :atomics.get(guest_sends, 1) == 2
      end
    end
  end

  defp held_meeting do
    user = insert(:user)

    insert(:meeting,
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
    )
  end

  defp announced_meeting(status) do
    start_time = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

    meeting =
      insert(:meeting,
        status: status,
        first_announced_at: DateTime.utc_now(:second),
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute)
      )

    {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
    {:ok, _guest} = GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))
    meeting
  end

  # The args `MeetingScheduler` wrote before the per-recipient claims.
  defp job_args("send_reschedule_emails", meeting) do
    %{
      "action" => "send_reschedule_emails",
      "meeting_id" => meeting.id,
      "rescheduled_to" => DateTime.to_iso8601(meeting.start_time),
      "status" => meeting.status,
      "original" => %{
        "start_time" => DateTime.to_iso8601(DateTime.add(meeting.start_time, -1, :day)),
        "end_time" => DateTime.to_iso8601(DateTime.add(meeting.end_time, -1, :day)),
        "attendee_video_url" => nil
      }
    }
  end

  defp job_args("send_cancellation_emails", meeting),
    do: %{"action" => "send_cancellation_emails", "meeting_id" => meeting.id}

  defp guest_sender(notice, opts \\ []) do
    test_pid = self()
    sends = :atomics.new(1, [])
    fun = if notice == "reschedule", do: :send_guest_reschedule, else: :send_guest_cancellation

    stub(Tymeslot.EmailServiceMock, fun, fn email, _details ->
      count = :atomics.add_get(sends, 1, 1)
      send(test_pid, {:guest, email})

      if Keyword.get(opts, :fail_first, false) and count == 1,
        do: {:error, :smtp_down},
        else: {:ok, :sent}
    end)

    sends
  end

  defp insert_job(args) do
    {:ok, job} = args |> EmailWorker.new() |> Oban.insert()
    job
  end

  # The same job run again, as a rescue or a duplicate delivery would.
  defp rerun(job), do: EmailWorker.perform(%{job | attempt: job.attempt + 1})
end
