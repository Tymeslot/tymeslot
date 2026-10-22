defmodule Tymeslot.Meetings.SessionMoveNoticeTest do
  @moduledoc """
  Who hears that the host moved a planned session, and how often: only the
  guests already told of the booking, and one notice per seat for moves made
  before the last notice went out, naming the time the participant last knew.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :emails

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  @action "send_seat_session_moved"

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
        duration_minutes: 90,
        is_active: true,
        max_participants: 10,
        fixed_dates: true,
        locations: [in_person_location([venue])]
      )

    {:ok, session} = PlannedSessions.add(meeting_type, user.id, at(10, ~T[18:00:00]))

    ada =
      insert(:participant, meeting: session, name: "Ada Lovelace", email: "ada@example.com")

    %{session: session, ada: ada}
  end

  defp at(days, time), do: Date.utc_today() |> Date.add(days) |> DateTime.new!(time, "Etc/UTC")

  defp move(ctx, to) do
    session = Repo.reload!(ctx.session)
    {:ok, moved} = PlannedSessions.move(session, session.organizer_user_id, to, nil)
    moved
  end

  defp notice_jobs, do: all_enqueued(worker: EmailWorker, args: %{"action" => @action})

  defp run(job), do: EmailHandlers.execute_email_action(@action, job.args, job.id)

  defp invited_guest(ctx, email) do
    {:ok, [guest]} = Guests.create_for_participant(ctx.session.id, ctx.ada.id, [email])
    {:ok, guest} = GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))
    guest
  end

  test "a guest whose invitation never went out does not hear of the move first", ctx do
    _invited = invited_guest(ctx, "invited@example.com")

    {:ok, [_uninvited]} =
      Guests.create_for_participant(ctx.session.id, ctx.ada.id, ["uninvited@example.com"])

    move(ctx, at(12, ~T[09:30:00]))
    [job] = notice_jobs()

    expect(Tymeslot.EmailServiceMock, :send_reschedule_email_to_attendee, fn _email, _details ->
      {:ok, "sent"}
    end)

    # Once only, and to the invited guest: a second call fails the test.
    expect(Tymeslot.EmailServiceMock, :send_guest_reschedule, fn email, _details ->
      assert email == "invited@example.com"
      {:ok, "sent"}
    end)

    assert :ok = run(job)
  end

  test "two moves before the notice runs send one email, from the original time", ctx do
    move(ctx, at(12, ~T[09:30:00]))
    move(ctx, at(14, ~T[11:00:00]))

    assert [job] = notice_jobs()

    expect(Tymeslot.EmailServiceMock, :send_reschedule_email_to_attendee, fn _email, details ->
      assert details.original_start_time == at(10, ~T[18:00:00])
      assert details.start_time == at(14, ~T[11:00:00])
      {:ok, "sent"}
    end)

    assert :ok = run(job)
  end

  test "a move after the notice went out is a new notice from the time it announced", ctx do
    move(ctx, at(12, ~T[09:30:00]))
    Repo.update_all(Oban.Job, set: [state: "completed"])

    move(ctx, at(14, ~T[11:00:00]))

    assert [job] = notice_jobs()
    assert job.args["from"] == DateTime.to_iso8601(at(12, ~T[09:30:00]))
  end

  test "moves that end where they began send nothing", ctx do
    move(ctx, at(12, ~T[09:30:00]))
    move(ctx, at(10, ~T[18:00:00]))

    # No expectation on the email service: any send fails the test.
    assert [job] = notice_jobs()
    assert :ok = run(job)
  end

  test "a move folded into a part-sent notice reaches the participant on its retry", ctx do
    invited_guest(ctx, "charles@example.com")
    move(ctx, at(12, ~T[09:30:00]))
    [job] = notice_jobs()

    expect(Tymeslot.EmailServiceMock, :send_reschedule_email_to_attendee, 2, fn _email, details ->
      send(self(), {:participant_told, details.start_time})
      {:ok, "sent"}
    end)

    expect(Tymeslot.EmailServiceMock, :send_guest_reschedule, 2, fn _email, details ->
      if details.start_time == at(12, ~T[09:30:00]),
        do: {:error, :smtp_unavailable},
        else: {:ok, "sent"}
    end)

    assert {:error, _reason} = run(job)

    # The job awaits its retry, so the next move folds into it.
    move(ctx, at(14, ~T[11:00:00]))
    assert [%{id: id}] = notice_jobs()
    assert id == job.id

    assert :ok = run(job)
    assert_received {:participant_told, first}
    assert_received {:participant_told, second}
    assert first == at(12, ~T[09:30:00])
    assert second == at(14, ~T[11:00:00])
  end
end
