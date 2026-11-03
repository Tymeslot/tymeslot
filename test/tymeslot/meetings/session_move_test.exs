defmodule Tymeslot.Meetings.SessionMoveTest do
  @moduledoc """
  The host moving a planned session with everyone booked on it: what is
  checked, what the move owes (the host's calendar event, the seats'
  calendar revisions, one email job per seat), the emails those jobs send,
  and the host reschedule request a planned session no longer takes.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :emails

  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Emails.Templates.AppointmentRescheduled
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    AvailabilityCache.clear_all()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "host@example.com", name: "Host")
    insert(:profile, user: user, timezone: "Etc/UTC")
    venue = insert(:venue, user: user, name: "Main Hall")

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Introduction to X",
        duration_minutes: 90,
        is_active: true,
        max_participants: 10,
        fixed_dates: true,
        locations: [in_person_location([venue])]
      )

    {:ok, session} = PlannedSessions.add(meeting_type, user.id, at(10, ~T[18:00:00]))
    %{user: user, meeting_type: meeting_type, session: session}
  end

  defp at(days, time), do: Date.utc_today() |> Date.add(days) |> DateTime.new!(time, "Etc/UTC")

  defp seat_job_args(session, participant) do
    %{
      "action" => "send_seat_session_moved",
      "meeting_id" => session.id,
      "participant_id" => participant.id,
      "from" => DateTime.to_iso8601(session.start_time)
    }
  end

  test "moves the session and owes its calendar event and every seat an update", ctx do
    ada =
      insert(:participant, meeting: ctx.session, name: "Ada Lovelace", email: "ada@example.com")

    assert {:ok, moved} =
             PlannedSessions.move(
               ctx.session,
               ctx.user.id,
               at(12, ~T[09:30:00]),
               at(11, ~T[12:00:00])
             )

    assert moved.start_time == at(12, ~T[09:30:00])
    assert moved.end_time == at(12, ~T[11:00:00])
    assert moved.registration_closes_at == at(11, ~T[12:00:00])
    assert moved.ical_sequence == ctx.session.ical_sequence + 1
    assert Repo.reload!(ada).ical_sequence == ada.ical_sequence + 1

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => moved.id}
    )

    assert_enqueued(worker: EmailWorker, args: seat_job_args(ctx.session, ada))
  end

  test "asks the guests to answer for the new time, but a decline stands", ctx do
    ada = insert(:participant, meeting: ctx.session, name: "Ada Lovelace")

    {:ok, [coming, not_coming]} =
      Guests.create_for_participant(ctx.session.id, ada.id, [
        "coming@example.com",
        "not.coming@example.com"
      ])

    {:ok, _accepted} = Guests.record_rsvp(coming.rsvp_token, :accepted)
    {:ok, _declined} = Guests.record_rsvp(not_coming.rsvp_token, :declined)

    {:ok, _moved} = PlannedSessions.move(ctx.session, ctx.user.id, at(12, ~T[09:30:00]), nil)

    assert {:ok, %{status: :pending}} = GuestQueries.get_by_token(coming.rsvp_token)
    assert {:ok, %{status: :declined}} = GuestQueries.get_by_token(not_coming.rsvp_token)
  end

  test "refuses a start in the past, a close after the new start and a cancelled session",
       ctx do
    assert {:error, :start_in_past} =
             PlannedSessions.move(ctx.session, ctx.user.id, at(-1, ~T[09:00:00]), nil)

    assert {:error, :invalid_registration_close} =
             PlannedSessions.move(
               ctx.session,
               ctx.user.id,
               at(12, ~T[09:00:00]),
               at(13, ~T[09:00:00])
             )

    cancelled = ctx.session |> Changeset.change(status: :cancelled) |> Repo.update!()

    assert {:error, :session_started} =
             PlannedSessions.move(cancelled, ctx.user.id, at(12, ~T[09:00:00]), nil)
  end

  test "refuses a session cancelled since the host's copy of it was read", ctx do
    # Cancelled in another tab: the row is cancelled, the struct the form
    # holds still reads as a live session.
    Repo.update!(Changeset.change(ctx.session, status: :cancelled))

    assert {:error, :not_found} =
             PlannedSessions.move(ctx.session, ctx.user.id, at(12, ~T[09:30:00]), nil)

    assert %{status: :cancelled, start_time: start_time} = Repo.reload!(ctx.session)
    assert start_time == at(10, ~T[18:00:00])
    refute_enqueued(worker: CalendarEventWorker, args: %{"action" => "update"})
  end

  test "refuses a time the host already has a booking at", ctx do
    {:ok, _other} = PlannedSessions.add(ctx.meeting_type, ctx.user.id, at(12, ~T[09:00:00]))

    assert {:error, _conflict} =
             PlannedSessions.move(ctx.session, ctx.user.id, at(12, ~T[09:30:00]), nil)

    assert Repo.reload!(ctx.session).start_time == at(10, ~T[18:00:00])
  end

  test "the seat job emails the participant and their guests the new time", ctx do
    ada =
      insert(:participant, meeting: ctx.session, name: "Ada Lovelace", email: "ada@example.com")

    {:ok, [charles]} =
      Guests.create_for_participant(ctx.session.id, ada.id, ["charles@example.com"])

    {:ok, _invited} = GuestQueries.mark_confirmation_sent(charles, DateTime.utc_now(:second))

    {:ok, _moved} = PlannedSessions.move(ctx.session, ctx.user.id, at(12, ~T[09:30:00]), nil)

    expect(Tymeslot.EmailServiceMock, :send_reschedule_email_to_attendee, fn email, details ->
      assert email == "ada@example.com"
      # The seat's own calendar entry, one revision on, so it replaces the
      # entry the participant already holds.
      assert details.uid == ParticipantSchema.calendar_uid(ada)
      assert details.ical_sequence == ada.ical_sequence + 1
      assert details.original_start_time == at(10, ~T[18:00:00])

      rendered = AppointmentRescheduled.render(:attendee, email, details)
      assert rendered.text_body =~ "has been moved"
      assert [ics] = Enum.filter(rendered.attachments, &(&1.content_type == "text/calendar"))
      assert ics.data =~ "SEQUENCE:#{ada.ical_sequence + 1}"
      {:ok, "sent"}
    end)

    expect(Tymeslot.EmailServiceMock, :send_guest_reschedule, fn email, details ->
      assert email == "charles@example.com"
      assert details.start_time == at(12, ~T[09:30:00])
      {:ok, "sent"}
    end)

    assert :ok = perform_job(EmailWorker, seat_job_args(ctx.session, ada))
  end

  test "a guest's failed copy retries the seat job without resending the participant's", ctx do
    ada =
      insert(:participant, meeting: ctx.session, name: "Ada Lovelace", email: "ada@example.com")

    {:ok, [charles]} =
      Guests.create_for_participant(ctx.session.id, ada.id, ["charles@example.com"])

    {:ok, _invited} = GuestQueries.mark_confirmation_sent(charles, DateTime.utc_now(:second))

    {:ok, _moved} = PlannedSessions.move(ctx.session, ctx.user.id, at(12, ~T[09:30:00]), nil)

    [job] =
      all_enqueued(worker: EmailWorker, args: %{"action" => "send_seat_session_moved"})

    expect(Tymeslot.EmailServiceMock, :send_reschedule_email_to_attendee, fn _email, _details ->
      {:ok, "sent"}
    end)

    expect(Tymeslot.EmailServiceMock, :send_guest_reschedule, 2, fn "charles@example.com",
                                                                    _details ->
      case Process.get(:guest_attempts, 0) do
        0 ->
          Process.put(:guest_attempts, 1)
          {:error, :smtp_unavailable}

        _retry ->
          {:ok, "sent"}
      end
    end)

    assert {:error, _reason} =
             EmailHandlers.execute_email_action("send_seat_session_moved", job.args, job.id)

    # The retry sends the guest's copy only; the participant's is not repeated.
    assert :ok = EmailHandlers.execute_email_action("send_seat_session_moved", job.args, job.id)
  end

  test "the seat job sends nothing to someone who has left", ctx do
    ada =
      insert(:participant,
        meeting: ctx.session,
        name: "Ada Lovelace",
        cancelled_at: DateTime.utc_now(:second)
      )

    # The email service mock has no expectation: any send would fail the test.
    assert {:discard, _reason} = perform_job(EmailWorker, seat_job_args(ctx.session, ada))
  end

  test "a planned session takes no host reschedule request", ctx do
    assert Policy.can_request_reschedule?(ctx.session) == {:error, {:not_reschedulable, :planned}}
  end
end
