defmodule Tymeslot.Integrations.Calendar.ExternalEndChangeNoticeTimingTest do
  @moduledoc """
  When the end-change notice runs against what else happened to the booking.
  Each seat hears "the end it knew, then the end that stands" once, however
  the host's changes interleave with the job: one waiting, running, retrying
  or already finished. A seat that joined after the change, or a booking
  rescheduled, cancelled, voided, started or whose host is leaving by the
  time the job runs, hears nothing.

  The end change goes through `Meetings.apply_external_end_change/2`, the
  calendar sync's write (`ExternalEndChangeEmailsTest` drives it through the
  Google sync itself). Jobs run through `EmailWorker.perform/1` with their
  stored row, so a retry is the same job id an Oban retry would carry. The
  real email templates are delivered to the test process.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :emails
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Test.ClockHelpers

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Notifications.Email.EndChangeEmails
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    use_real_emails()
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    %{user: user} = create_always_bookable_profile(timezone: "Etc/UTC")
    start_time = DateTime.new!(Date.add(Date.utc_today(), 10), ~T[10:00:00], "Etc/UTC")

    meeting_type = insert(:meeting_type, user: user, user_id: user.id)

    meeting =
      insert(:meeting,
        meeting_type_id: meeting_type.id,
        organizer_user_id: user.id,
        organizer_email: user.email,
        status: "confirmed",
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute),
        duration: 30,
        attendee_timezone: "Etc/UTC"
      )

    %{user: user, meeting: meeting}
  end

  describe "a change landing while the notice is already under way" do
    # O1: the job reads the meeting after the second change, so it tells the
    # end that stands; the job the second change scheduled then finds every
    # seat told.
    test "a running notice tells the final end, and the next one tells nobody", ctx do
      change_end(ctx.meeting, ~T[11:30:00])
      [first] = end_change_jobs()
      put_state(first, "executing")

      change_end(ctx.meeting, ~T[12:00:00])
      assert [%{id: first_id}, second] = end_change_jobs()
      assert first_id == first.id

      assert :ok = run(first)

      assert told(ctx.meeting.attendee_email) =~
               "now ends at 12:00 PM UTC instead of 10:30 AM UTC"

      assert_host_told()

      assert {:discard, _reason} = run(second)
      refute_received {:email, _another}
    end

    # The same race the other way round: the job finished with the first
    # change, so the next one tells the step from it, not from the start.
    test "a notice that already went out is followed by the step from it", ctx do
      change_end(ctx.meeting, ~T[11:30:00])
      [first] = end_change_jobs()
      put_state(first, "executing")
      assert :ok = run(first)

      assert told(ctx.meeting.attendee_email) =~
               "now ends at 11:30 AM UTC instead of 10:30 AM UTC"

      assert_host_told()

      change_end(ctx.meeting, ~T[12:00:00])
      [_first, second] = end_change_jobs()

      assert :ok = run(second)

      assert told(ctx.meeting.attendee_email) =~
               "now ends at 12:00 PM UTC instead of 11:30 AM UTC"

      assert_host_told()
    end

    # O2: the first job failed and waits to retry when the second change
    # lands; whichever runs first tells the end that stands, once.
    test "a notice waiting to retry tells the final end once", ctx do
      change_end(ctx.meeting, ~T[11:30:00])
      [first] = end_change_jobs()

      use_mock_emails()

      expect(EmailServiceMock, :send_end_change_to_attendee, fn _email, _details ->
        {:error, :timeout}
      end)

      assert {:error, _reason} = run(first)
      put_state(first, "retryable")
      use_real_emails()

      change_end(ctx.meeting, ~T[12:00:00])
      assert [%{id: first_id}, second] = end_change_jobs()
      assert first_id == first.id

      assert :ok = run(first, attempt: 2)

      assert told(ctx.meeting.attendee_email) =~
               "now ends at 12:00 PM UTC instead of 10:30 AM UTC"

      assert_host_told()

      assert {:discard, _reason} = run(second)
      refute_received {:email, _another}
    end

    # T1: the sync compared the event against a meeting it read before the
    # first notice went out. What the booker is told comes from what they
    # were told, not from that read.
    test "a change compared against an old read still tells the step the booker knows", ctx do
      stale_read = ctx.meeting

      change_end(ctx.meeting, ~T[11:30:00])
      [first] = end_change_jobs()
      put_state(first, "executing")
      assert :ok = run(first)
      told(ctx.meeting.attendee_email)
      assert_host_told()
      put_state(first, "completed")

      assert :ok = Meetings.apply_external_end_change(stale_read, at(ctx.meeting, ~T[12:00:00]))
      [second] = Enum.reject(end_change_jobs(), &(&1.id == first.id))

      assert :ok = run(second)

      assert told(ctx.meeting.attendee_email) =~
               "now ends at 12:00 PM UTC instead of 11:30 AM UTC"
    end
  end

  describe "a group meeting" do
    # O3: their confirmation already gave them the new end.
    test "a participant who booked after the change is not told about it", ctx do
      meeting = group!(ctx.meeting)
      early = insert(:participant, meeting: meeting, timezone: "Etc/UTC")

      change_end(meeting, ~T[11:30:00])
      late = insert(:participant, meeting: meeting, timezone: "Etc/UTC")
      [job] = end_change_jobs()

      assert :ok = run(job)
      assert told(early.email) =~ "now ends at 11:30 AM UTC instead of 10:30 AM UTC"
      host = assert_host_told()
      assert host.text_body =~ "We emailed 1 participant the new end time"
      refute host.text_body =~ late.name
      refute_received {:email, _late}
    end

    # The host's notice counts every seat the job reached, though only the
    # seat the first run missed is written to again.
    test "a retry writes only to the seat the first run missed, and the host hears of both",
         ctx do
      meeting = group!(ctx.meeting)
      reached = insert(:participant, meeting: meeting, timezone: "Etc/UTC")
      missed = insert(:participant, meeting: meeting, timezone: "Etc/UTC")
      change_end(meeting, ~T[11:30:00])
      [job] = end_change_jobs()

      use_mock_emails()
      test_pid = self()

      expect(EmailServiceMock, :send_end_change_to_attendee, 2, fn email, _details ->
        if email == missed.email, do: {:error, :timeout}, else: {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_end_change_to_organizer, 0, fn _meeting, _email, _notice ->
        {:ok, :sent}
      end)

      assert {:error, _reason} = run(job)

      expect(EmailServiceMock, :send_end_change_to_attendee, fn email, details ->
        send(test_pid, {:retried, email, details.original_end_time})
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_end_change_to_organizer, fn _meeting, _email, notice ->
        send(test_pid, {:host, notice})
        {:ok, :sent}
      end)

      assert :ok = run(job, attempt: 2)

      expected_known_end = at(meeting, ~T[10:30:00])
      missed_email = missed.email
      assert_received {:retried, ^missed_email, ^expected_known_end}
      assert_received {:host, notice}
      assert Enum.sort(notice.attendees) == Enum.sort([reached.name, missed.name])

      for participant <- [reached, missed] do
        assert Repo.get!(ParticipantSchema, participant.id).notified_end_time ==
                 at(meeting, ~T[11:30:00])
      end
    end
  end

  # The host's notice says which end the change replaced. A first run that
  # told the booker has moved their record on, so a retry must not read the
  # end it replaced from there.
  describe "the host's notice on a retry" do
    test "keeps the end replaced when the booker was told and a guest was missed", ctx do
      {:ok, _guests} = Guests.create_for_meeting(ctx.meeting.id, ["guest@example.com"])
      change_end(ctx.meeting, ~T[11:30:00])
      [job] = end_change_jobs()
      use_mock_emails()

      expect(EmailServiceMock, :send_end_change_to_attendee, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_guest_end_change, fn _email, _details ->
        {:error, :timeout}
      end)

      assert {:error, _reason} = run(job)

      expect(EmailServiceMock, :send_guest_end_change, fn _email, _details -> {:ok, :sent} end)
      expect_host_notice()
      assert :ok = run(job, attempt: 2)

      assert_host_heard(at(ctx.meeting, ~T[10:30:00]))
    end

    test "keeps the end replaced when the host's own notice failed", ctx do
      change_end(ctx.meeting, ~T[11:30:00])
      [job] = end_change_jobs()
      use_mock_emails()

      expect(EmailServiceMock, :send_end_change_to_attendee, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_end_change_to_organizer, fn _meeting, _email, _notice ->
        {:error, :timeout}
      end)

      assert {:error, _reason} = run(job)

      expect_host_notice()
      assert :ok = run(job, attempt: 2)

      assert_host_heard(at(ctx.meeting, ~T[10:30:00]))
    end

    test "keeps the end replaced on a group meeting whose host notice failed", ctx do
      meeting = group!(ctx.meeting)
      insert(:participant, meeting: meeting, timezone: "Etc/UTC")
      change_end(meeting, ~T[11:30:00])
      [job] = end_change_jobs()
      use_mock_emails()

      expect(EmailServiceMock, :send_end_change_to_attendee, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_end_change_to_organizer, fn _meeting, _email, _notice ->
        {:error, :timeout}
      end)

      assert {:error, _reason} = run(job)

      expect_host_notice()
      assert :ok = run(job, attempt: 2)

      assert_host_heard(at(meeting, ~T[10:30:00]))
    end
  end

  describe "the host's notice on a retry, for a meeting with no end of its own kept" do
    # A row from before the meeting kept its end: the first run takes the
    # end a reached seat knew, and the retry, whose seats were all reached,
    # must find that value again rather than have none.
    test "keeps the end a seat knew on the first run", ctx do
      meeting = group!(ctx.meeting)
      participant = insert(:participant, meeting: meeting, timezone: "Etc/UTC")
      change_end(meeting, ~T[11:30:00])

      Repo.update_all(from(m in MeetingSchema, where: m.id == ^meeting.id),
        set: [notified_end_time: nil]
      )

      assert Repo.get!(ParticipantSchema, participant.id).notified_end_time ==
               at(meeting, ~T[10:30:00])

      [job] = end_change_jobs()
      use_mock_emails()

      expect(EmailServiceMock, :send_end_change_to_attendee, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_end_change_to_organizer, fn _meeting, _email, _notice ->
        {:error, :timeout}
      end)

      assert {:error, _reason} = run(job)

      expect_host_notice()
      assert :ok = run(job, attempt: 2)

      assert_host_heard(at(meeting, ~T[10:30:00]))
    end
  end

  describe "a booking that moved on before the notice ran" do
    test "a reschedule in the meantime announces the new time and no stale end", ctx do
      {:ok, _guests} = Guests.create_for_meeting(ctx.meeting.id, ["guest@example.com"])
      change_end(ctx.meeting, ~T[11:30:00])
      [job] = end_change_jobs()

      stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user, _from, _to ->
        {:ok, []}
      end)

      params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 12)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "Etc/UTC"
      }

      assert {:ok, _rescheduled} = Reschedule.execute(ctx.meeting.uid, params, ctx.user.id)
      assert {:ok, %{notified_end_time: nil}} = MeetingQueries.get_meeting(ctx.meeting.id)
      assert [%{notified_end_time: nil}] = GuestQueries.list_live_for_meeting(ctx.meeting.id)

      assert {:discard, "Meeting start moved"} = run(job)
      refute_received {:email, _stale}
    end

    # The waiting job takes the start of the change that joined it: the
    # second change is announced, from the end the reschedule gave.
    test "an end change after a reschedule in the meantime is still announced", ctx do
      change_end(ctx.meeting, ~T[11:30:00])

      stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user, _from, _to ->
        {:ok, []}
      end)

      params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 12)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "Etc/UTC"
      }

      assert {:ok, _rescheduled} = Reschedule.execute(ctx.meeting.uid, params, ctx.user.id)
      {:ok, rescheduled} = MeetingQueries.get_meeting(ctx.meeting.id)
      change_end(rescheduled, ~T[16:00:00])

      assert [job] = end_change_jobs()
      assert job.args["start_time"] == DateTime.to_iso8601(rescheduled.start_time)

      assert :ok = run(job)
      # The reschedule kept the lengthened meeting's 90 minutes.
      assert told(ctx.meeting.attendee_email) =~
               "now ends at 04:00 PM UTC instead of 03:30 PM UTC"
    end

    for {label, reason, move_on} <- [
          {"cancelled", "Meeting not confirmed",
           quote(do: fn meeting -> Changeset.change(meeting, status: "cancelled") end)},
          {"sent a reschedule request", "Meeting time no longer holds",
           quote(
             do: fn meeting ->
               Changeset.change(meeting, reschedule_requested_at: ~U[2026-01-01 00:00:00Z])
             end
           )}
        ] do
      test "a booking #{label} since tells nobody", ctx do
        change_end(ctx.meeting, ~T[11:30:00])
        [job] = end_change_jobs()

        {:ok, meeting} = MeetingQueries.get_meeting(ctx.meeting.id)
        meeting |> unquote(move_on).() |> Repo.update!()

        assert {:discard, unquote(reason)} = run(job)
        refute_received {:email, _any}
      end
    end

    test "a meeting that has started tells nobody", ctx do
      change_end(ctx.meeting, ~T[11:30:00])
      [job] = end_change_jobs()
      # Run in the test process, where the frozen clock applies.
      freeze_clock(DateTime.add(ctx.meeting.start_time, 5, :minute))

      assert {:discard, "Meeting already started"} =
               EndChangeEmails.handle_end_change_emails(job.args, job.id)

      refute_received {:email, _any}
    end

    test "a host leaving tells nobody", ctx do
      change_end(ctx.meeting, ~T[11:30:00])
      [job] = end_change_jobs()

      Repo.update_all(from(u in UserSchema, where: u.id == ^ctx.user.id),
        set: [deletion_scheduled_at: DateTime.utc_now(:second)]
      )

      assert {:discard, "Host account pending deletion"} = run(job)
      refute_received {:email, _any}
    end
  end

  defp change_end(meeting, end_time) do
    {:ok, current} = MeetingQueries.get_meeting(meeting.id)
    assert :ok = Meetings.apply_external_end_change(current, at(meeting, end_time))
  end

  defp at(meeting, time), do: DateTime.new!(DateTime.to_date(meeting.start_time), time, "Etc/UTC")

  defp group!(meeting), do: meeting |> Changeset.change(capacity: 4) |> Repo.update!()

  defp end_change_jobs do
    Oban.Job
    |> where([j], fragment("?->>'action'", j.args) == "send_end_change_emails")
    |> order_by([j], asc: j.id)
    |> Repo.all()
  end

  defp put_state(job, state),
    do: Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])

  defp run(job, opts \\ []),
    do: EmailWorker.perform(%{job | attempt: Keyword.get(opts, :attempt, 1)})

  defp use_real_emails,
    do: Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

  defp use_mock_emails,
    do: Application.put_env(:tymeslot, :email_service_module, EmailServiceMock)

  defp expect_host_notice do
    test_pid = self()

    expect(EmailServiceMock, :send_end_change_to_organizer, fn _meeting, _email, notice ->
      send(test_pid, {:host_notice, notice})
      {:ok, :sent}
    end)
  end

  defp assert_host_heard(previous_end) do
    assert_received {:host_notice, notice}
    assert notice.previous_end_time == previous_end
  end

  defp told(address) do
    assert_received {:email, %Swoosh.Email{to: [{_name, ^address}]} = email}
    email.text_body
  end

  defp assert_host_told do
    assert_received {:email, %Swoosh.Email{subject: subject} = email}
    assert subject =~ "now ends at"
    email
  end
end
