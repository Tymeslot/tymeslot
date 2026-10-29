defmodule Tymeslot.Meetings.PlannedSessionsTest do
  @moduledoc """
  Fixed-date group meeting types: the sessions a host plans, what the
  booking page offers for them, and what booking, leaving and moving a seat
  do to a session that exists because it was planned.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.{CancelSeat, Create, RescheduleSeat}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    AvailabilityCache.clear_all()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "host@example.com", name: "Host")
    # No availability schedule is opened: a fixed-date type is offered from
    # its sessions alone, so the schedule must never be why it works.
    profile = insert(:profile, user: user, timezone: "Etc/UTC")
    venue = insert(:venue, user: user, name: "Main Hall")

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Introduction to X",
        duration_minutes: 90,
        is_active: true,
        max_participants: 2,
        fixed_dates: true,
        locations: [in_person_location([venue])]
      )

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  defp at(days, time),
    do: Date.utc_today() |> Date.add(days) |> DateTime.new!(time, "Etc/UTC")

  defp plan!(meeting_type, starts_at, opts \\ []) do
    {:ok, session} = PlannedSessions.add(meeting_type, meeting_type.user_id, starts_at, opts)
    session
  end

  defp book(ctx, starts_at, email) do
    Create.execute(
      %{
        date: DateTime.to_date(starts_at),
        time: Calendar.strftime(starts_at, "%H:%M"),
        duration: "90min",
        user_timezone: "Etc/UTC",
        organizer_user_id: ctx.user.id,
        meeting_type_id: ctx.meeting_type.id
      },
      %{"name" => "Booker #{email}", "email" => email}
    )
  end

  defp request(ctx),
    do: %{profile: ctx.profile, user_timezone: "Etc/UTC", meeting_type: ctx.meeting_type}

  defp offered(ctx, starts_at) do
    {:ok, slots} =
      Offer.slots_for_date(request(ctx), Date.to_iso8601(DateTime.to_date(starts_at)), 90)

    slots
  end

  describe "planning a session" do
    test "creates the type's group meeting at once, without a booker, on the host's calendar",
         ctx do
      starts_at = at(5, ~T[18:00:00])
      session = plan!(ctx.meeting_type, starts_at)

      assert %MeetingSchema{
               planned: true,
               status: :confirmed,
               capacity: 2,
               attendee_email: nil,
               title: "Introduction to X"
             } = session

      assert session.start_time == starts_at
      assert session.end_time == DateTime.add(starts_at, 90, :minute)
      assert session.meeting_type_id == ctx.meeting_type.id

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "create", "meeting_id" => session.id}
      )
    end

    test "refuses a type without fixed dates, a start in the past and a bad deadline", ctx do
      starts_at = at(5, ~T[18:00:00])
      plain = insert(:meeting_type, user: ctx.user, max_participants: 2)

      assert {:error, :not_fixed_dates} = PlannedSessions.add(plain, ctx.user.id, starts_at)

      assert {:error, :start_in_past} =
               PlannedSessions.add(
                 ctx.meeting_type,
                 ctx.user.id,
                 DateTime.add(DateTime.utc_now(), -60)
               )

      assert {:error, :invalid_registration_close} =
               PlannedSessions.add(ctx.meeting_type, ctx.user.id, starts_at,
                 registration_closes_at: DateTime.add(starts_at, 60)
               )

      assert {:error, :invalid_registration_close} =
               PlannedSessions.add(ctx.meeting_type, ctx.user.id, starts_at,
                 registration_closes_at: DateTime.add(DateTime.utc_now(), -60)
               )

      assert Repo.all(MeetingSchema) == []
    end

    test "refuses a time the host already has a booking at", ctx do
      starts_at = at(5, ~T[18:00:00])
      plan!(ctx.meeting_type, starts_at)

      assert {:error, _conflict} =
               PlannedSessions.add(
                 ctx.meeting_type,
                 ctx.user.id,
                 DateTime.add(starts_at, 30, :minute)
               )
    end
  end

  describe "what the booking page offers" do
    test "only the planned sessions, with their seats", ctx do
      first = at(5, ~T[18:00:00])
      second = at(9, ~T[09:30:00])
      plan!(ctx.meeting_type, first)
      plan!(ctx.meeting_type, second)

      assert [%{time: "6:00 PM", seats_left: 2, capacity: 2}] = offered(ctx, first)
      assert [%{time: "9:30 AM"}] = offered(ctx, second)
      assert offered(ctx, at(6, ~T[18:00:00])) == []

      {:ok, days} =
        Offer.days_in_range(request(ctx), Date.utc_today(), Date.add(Date.utc_today(), 14), 90)

      assert days |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               Enum.sort([
                 Date.to_iso8601(DateTime.to_date(first)),
                 Date.to_iso8601(DateTime.to_date(second))
               ])
    end

    test "nothing once registration has closed or the session is full", ctx do
      closing = at(5, ~T[18:00:00])
      full = at(7, ~T[18:00:00])

      closed =
        plan!(ctx.meeting_type, closing, registration_closes_at: DateTime.add(closing, -3600))

      plan!(ctx.meeting_type, full)

      # Registration closing is a moment in the future when planned; move it
      # into the past as time would.
      Repo.update_all(
        from(m in MeetingSchema, where: m.id == ^closed.id),
        set: [registration_closes_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, _seat} = book(ctx, full, "one@example.com")
      assert {:ok, _seat} = book(ctx, full, "two@example.com")
      AvailabilityCache.clear_all()

      assert offered(ctx, closing) == []
      assert offered(ctx, full) == []
    end
  end

  describe "booking" do
    test "joins the planned session rather than creating a meeting", ctx do
      starts_at = at(5, ~T[18:00:00])
      session = plan!(ctx.meeting_type, starts_at)

      assert {:ok, booked} = book(ctx, starts_at, "one@example.com")
      assert booked.id == session.id
      assert [%{email: "one@example.com"}] = ParticipantQueries.list_live_for_meeting(session.id)
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    test "refuses any time that is not an open session", ctx do
      starts_at = at(5, ~T[18:00:00])
      plan!(ctx.meeting_type, starts_at)

      assert {:error, :slot_taken} = book(ctx, at(5, ~T[10:00:00]), "one@example.com")
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    test "does not bring a cancelled session back as an unplanned slot", ctx do
      starts_at = at(5, ~T[18:00:00])
      session = plan!(ctx.meeting_type, starts_at)
      {:ok, _cancelled} = PlannedSessions.cancel(session, ctx.user.id)

      assert {:error, :slot_taken} = book(ctx, starts_at, "one@example.com")
      assert [%{status: :cancelled}] = Repo.all(MeetingSchema)
    end
  end

  describe "a session's last participant leaving" do
    test "cancelling the seat leaves the session on", ctx do
      starts_at = at(5, ~T[18:00:00])
      session = plan!(ctx.meeting_type, starts_at)
      {:ok, _seat} = book(ctx, starts_at, "one@example.com")
      [participant] = ParticipantQueries.list_live_for_meeting(session.id)

      assert {:ok, _cancelled} = CancelSeat.execute(participant.management_token)

      assert ParticipantQueries.list_live_for_meeting(session.id) == []
      assert Repo.get!(MeetingSchema, session.id).status == :confirmed
    end

    test "moving the seat to another session leaves the first one on", ctx do
      first = at(5, ~T[18:00:00])
      second = at(9, ~T[18:00:00])
      first_session = plan!(ctx.meeting_type, first)
      second_session = plan!(ctx.meeting_type, second)
      {:ok, _seat} = book(ctx, first, "one@example.com")
      [participant] = ParticipantQueries.list_live_for_meeting(first_session.id)

      assert {:ok, %{meeting: moved_to}} =
               RescheduleSeat.execute(
                 participant.management_token,
                 %{
                   date: Date.to_iso8601(DateTime.to_date(second)),
                   time: "18:00",
                   duration: "90min",
                   user_timezone: "Etc/UTC"
                 },
                 ctx.user.id
               )

      assert moved_to.id == second_session.id
      assert Repo.get!(MeetingSchema, first_session.id).status == :confirmed
    end

    test "a seat cannot move to a time that is not a session", ctx do
      starts_at = at(5, ~T[18:00:00])
      session = plan!(ctx.meeting_type, starts_at)
      {:ok, _seat} = book(ctx, starts_at, "one@example.com")
      [participant] = ParticipantQueries.list_live_for_meeting(session.id)

      assert {:error, :slot_taken} =
               RescheduleSeat.execute(
                 participant.management_token,
                 %{
                   date: Date.to_iso8601(Date.add(Date.utc_today(), 6)),
                   time: "18:00",
                   duration: "90min",
                   user_timezone: "Etc/UTC"
                 },
                 ctx.user.id
               )

      assert Repo.aggregate(MeetingSchema, :count) == 1
    end
  end

  describe "moving when registration closes" do
    test "extends, reopens and closes registration, up to the start", ctx do
      starts_at = at(10, ~T[18:00:00])
      session = plan!(ctx.meeting_type, starts_at, registration_closes_at: at(2, ~T[12:00:00]))

      assert {:ok, extended} =
               PlannedSessions.set_registration_close(session, ctx.user.id, at(9, ~T[12:00:00]))

      assert extended.registration_closes_at == at(9, ~T[12:00:00])
      assert PlannedSessions.open?(extended)

      assert {:ok, closed} =
               PlannedSessions.set_registration_close(extended, ctx.user.id, at(-1, ~T[12:00:00]))

      refute PlannedSessions.open?(closed)
      assert PlannedSessions.next_open(ctx.meeting_type) == nil
      assert offered(ctx, starts_at) == []

      assert {:ok, until_start} = PlannedSessions.set_registration_close(closed, ctx.user.id, nil)
      assert until_start.registration_closes_at == nil
      assert PlannedSessions.next_open(ctx.meeting_type).id == session.id
    end

    test "refuses a close after the start, and a session that has started", ctx do
      starts_at = at(10, ~T[18:00:00])
      session = plan!(ctx.meeting_type, starts_at)

      assert {:error, :invalid_registration_close} =
               PlannedSessions.set_registration_close(session, ctx.user.id, at(11, ~T[12:00:00]))

      assert {:error, :session_started} =
               PlannedSessions.set_registration_close(
                 session,
                 ctx.user.id,
                 nil,
                 at(10, ~T[18:30:00])
               )

      assert Repo.get!(MeetingSchema, session.id).registration_closes_at == nil
    end
  end

  describe "a session nobody has signed up for" do
    test "sends no reminder, and is no booking in the analytics", ctx do
      {:ok, session} = PlannedSessions.add(ctx.meeting_type, ctx.user.id, at(3, ~T[10:00:00]))
      window = {DateTime.add(DateTime.utc_now(), -3600), DateTime.add(DateTime.utc_now(), 3600)}

      # The email service mock has no expectation: any send would fail the test.
      assert :ok =
               EmailHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => session.id,
                 "reminder_value" => 30,
                 "reminder_unit" => "minutes"
               })

      assert Meetings.count_bookings(ctx.user.id, elem(window, 0), elem(window, 1)) == 0

      insert(:participant, meeting: session, email: "ada@example.com")
      assert Meetings.count_bookings(ctx.user.id, elem(window, 0), elem(window, 1)) == 1
    end

    test "counts in the analytics when people signed up, not when it was planned", ctx do
      session = plan!(ctx.meeting_type, at(3, ~T[10:00:00]))
      now = DateTime.utc_now(:second)
      planned_at = DateTime.add(now, -10, :day)

      session
      |> Changeset.change(inserted_at: planned_at)
      |> Repo.update!()

      insert(:participant, meeting: session, email: "ada@example.com")
      insert(:participant, meeting: session, email: "bob@example.com")

      assert Meetings.count_bookings(ctx.user.id, DateTime.add(now, -7, :day), now) == 1

      assert Meetings.count_bookings(
               ctx.user.id,
               DateTime.add(planned_at, -1, :day),
               DateTime.add(planned_at, 1, :day)
             ) == 0
    end
  end

  describe "the host's booking limits" do
    test "count a planned session only once someone holds a seat, and then once", ctx do
      # A cap of one a day, across the host's whole account.
      profile = %{ctx.profile | max_bookings_per_day: 1}
      other_type = insert(:meeting_type, user: ctx.user, duration_minutes: 30)
      session = plan!(ctx.meeting_type, at(5, ~T[18:00:00]))
      morning = at(5, ~T[10:00:00])

      assert :ok = Checker.check_booking_allowed(ctx.user.id, profile, other_type, morning)

      insert(:participant, meeting: session, email: "one@example.com")
      insert(:participant, meeting: session, email: "two@example.com")

      assert {:error, :booking_limit_reached} =
               Checker.check_booking_allowed(ctx.user.id, profile, other_type, morning)

      profile = %{profile | max_bookings_per_day: 2}
      assert :ok = Checker.check_booking_allowed(ctx.user.id, profile, other_type, morning)
    end
  end

  describe "registration closing while a booking commits" do
    test "the seat is refused once registration has closed, read under the lock", ctx do
      starts_at = at(5, ~T[18:00:00])
      session = plan!(ctx.meeting_type, starts_at)
      # Registration closes after the booker's pre-check would have passed:
      # `book_seat/3` is then all that stands between them and the session.
      {:ok, _closed} =
        PlannedSessions.set_registration_close(session, ctx.user.id, at(-1, ~T[12:00:00]))

      attrs = %{
        uid: UUID.generate(),
        title: ctx.meeting_type.name,
        start_time: starts_at,
        end_time: DateTime.add(starts_at, 90, :minute),
        duration: 90,
        status: :confirmed,
        organizer_user_id: ctx.user.id,
        organizer_name: "Host",
        organizer_email: "host@example.com",
        meeting_type_id: ctx.meeting_type.id
      }

      seat = %{
        participant: %{
          name: "Late",
          email: "late@example.com",
          timezone: "Etc/UTC",
          locale: "en",
          custom_field_answers: %{}
        },
        guest_emails: [],
        max_participants: 2
      }

      assert {:error, :slot_full} = GroupScheduling.book_seat(attrs, seat, join_only: true)
      assert ParticipantQueries.list_live_for_meeting(session.id) == []
    end
  end

  describe "acting on another host's plan" do
    setup ctx do
      %{session: plan!(ctx.meeting_type, at(10, ~T[18:00:00])), stranger: insert(:user)}
    end

    test "planning a date on their type is refused", ctx do
      assert {:error, :not_found} =
               PlannedSessions.add(ctx.meeting_type, ctx.stranger.id, at(12, ~T[18:00:00]))

      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    test "moving their registration close is refused", ctx do
      assert {:error, :not_found} =
               PlannedSessions.set_registration_close(
                 ctx.session,
                 ctx.stranger.id,
                 at(-1, ~T[12:00:00])
               )

      assert Repo.reload!(ctx.session).registration_closes_at == nil
    end

    test "moving their session is refused", ctx do
      assert {:error, :not_found} =
               PlannedSessions.move(ctx.session, ctx.stranger.id, at(12, ~T[09:00:00]), nil)

      assert Repo.reload!(ctx.session).start_time == at(10, ~T[18:00:00])
    end
  end

  describe "the meeting type" do
    test "refuses fixed dates on a type that is not a group type", ctx do
      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, %{
          name: "Solo",
          duration_minutes: 30,
          user_id: ctx.user.id,
          max_participants: 1,
          fixed_dates: true
        })

      refute changeset.valid?
      assert {"fixed dates need group bookings", _opts} = changeset.errors[:fixed_dates]
    end
  end
end
