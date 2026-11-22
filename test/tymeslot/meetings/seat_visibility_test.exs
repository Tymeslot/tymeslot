defmodule Tymeslot.Meetings.SeatVisibilityTest do
  @moduledoc """
  A seat awaiting email verification holds capacity but is shown to nobody:
  not on rosters, in counts the host sees, on calendars, or behind its
  management token. The last visible seat leaving takes the held seat with
  it.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Tymeslot.Bookings.{CancelSeat, Create, RescheduleSeat}
  alias Tymeslot.EmailServiceMock

  alias Tymeslot.Meetings.{
    CalendarExport,
    Cancellation,
    EmailVerification,
    EmailVerificationJobs,
    Guests,
    MeetingListQueries,
    MeetingSchema,
    ParticipantQueries,
    Recipient,
    SeatLookup,
    Seats,
    SeatView
  }

  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker

  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")
    profile = insert(:profile, user: user, timezone: "America/New_York")
    open_schedule_for(profile)

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        is_active: true,
        max_participants: 3,
        allow_guests: true
      )

    params = %{
      date: Date.add(Date.utc_today(), 2),
      time: "14:00",
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    {:ok, meeting} =
      Create.execute(params, %{"name" => "Verified", "email" => "verified@example.com"})

    unverified =
      insert(:participant,
        meeting: meeting,
        name: "Waiting",
        email: "waiting@example.com",
        verification_deadline_at: DateTime.add(DateTime.utc_now(:second), 30, :minute)
      )

    verified =
      meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Enum.find(&(&1.email == "verified@example.com"))

    %{
      meeting_type: meeting_type,
      params: params,
      meeting: meeting,
      verified: verified,
      unverified: unverified
    }
  end

  test "an unverified seat takes capacity", %{meeting: meeting, meeting_type: meeting_type} do
    assert Seats.seats_left(meeting, meeting_type.max_participants) == 1
    assert Seats.seats_left_by_meeting([meeting]) == %{meeting.id => 1}
    assert ParticipantQueries.count_seats_held(meeting.id) == 2
  end

  test "a booking for two seats is refused as full", %{params: params} do
    assert {:error, _full} =
             params
             |> Map.put(:guest_emails, ["pair.guest@example.com"])
             |> Create.execute(%{"name" => "Pair", "email" => "pair@example.com"})
  end

  test "the public page counts the held seat", %{meeting: meeting, meeting_type: meeting_type} do
    from_utc = DateTime.add(meeting.start_time, -1, :hour)
    to_utc = DateTime.add(meeting.start_time, 1, :hour)

    counts = Seats.seat_counts_for_range(meeting_type.id, from_utc, to_utc)
    assert counts[meeting.start_time] == 2
  end

  test "nobody is shown the unverified seat", %{meeting: meeting, verified: verified} do
    reloaded = Repo.get!(MeetingSchema, meeting.id)

    assert [recipient] = Recipient.for_meeting(reloaded)
    assert recipient.email == "verified@example.com"

    assert [card] = List.wrap(MeetingListQueries.preload_live_participants(reloaded))
    assert [%{email: "verified@example.com"}] = card.participants

    assert Seats.seats_taken(meeting.id) == 1
    assert Seats.counts_by_meeting([meeting.id])[meeting.id] == %{participants: 1, seats_taken: 1}
    assert ParticipantQueries.count_live_for_meeting(meeting.id) == 1

    assert {:ok, view} = SeatView.load(reloaded, verified.id, nil)
    assert SeatView.seats_taken(view) == 1
  end

  test "the organiser's meeting card lists neither the unverified seat nor its guests", %{
    meeting: meeting,
    verified: verified,
    unverified: unverified
  } do
    {:ok, _kept} = Guests.create_for_participant(meeting.id, verified.id, ["kept@example.com"])

    {:ok, _held} =
      Guests.create_for_participant(meeting.id, unverified.id, ["held@example.com"])

    assert [card] =
             MeetingListQueries.list_meetings_for_organizer_paginated_cursor(
               meeting.organizer_user_id,
               []
             )

    assert [%{email: "verified@example.com"}] = card.participants
    assert [%{email: "kept@example.com"}] = card.guests
    assert Seats.seats_taken(card.participants, card.guests) == 2
  end

  test "an unverified seat's token opens nothing", %{meeting: meeting, unverified: unverified} do
    assert {:error, :not_found} = SeatLookup.fetch_live_seat(unverified.management_token)

    reloaded = Repo.get!(MeetingSchema, meeting.id)
    booker_view = SeatView.for_booker(reloaded, "waiting@example.com")

    assert booker_view.status == :awaiting_verification
    assert CalendarExport.for_booker(booker_view) == :none
  end

  test "an unverified seat's token cannot move it", %{meeting: meeting, unverified: unverified} do
    new_params = %{
      date: Date.to_iso8601(Date.add(Date.utc_today(), 3)),
      time: "10:00",
      duration: "30min",
      user_timezone: "America/New_York"
    }

    assert {:error, :meeting_not_found} =
             RescheduleSeat.execute(
               unverified.management_token,
               new_params,
               meeting.organizer_user_id
             )

    assert {:ok, %{cancelled_at: nil, meeting_id: meeting_id}} =
             ParticipantQueries.get(unverified.id)

    assert meeting_id == meeting.id
  end

  test "the last visible seat leaving holds the slot again, keeping the held seat", %{
    meeting: meeting,
    verified: verified,
    unverified: unverified
  } do
    assert {:ok, :meeting_cancelled} = CancelSeat.execute(verified.management_token)

    assert Repo.get!(MeetingSchema, meeting.id).status == :awaiting_verification
    assert {:ok, %{cancelled_at: nil}} = ParticipantQueries.get(unverified.id)

    refute_enqueued(worker: EmailWorker, args: %{"participant_id" => unverified.id})

    expect(EmailServiceMock, :send_cancellation_email_to_attendee, fn email, _details ->
      assert email == "verified@example.com"
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_seat_update_to_organizer, fn :cancelled, email, _details ->
      assert email == "organizer@example.com"
      {:ok, "sent"}
    end)

    jobs =
      Enum.filter(
        all_enqueued(worker: EmailWorker),
        &(&1.args["action"] == "send_seat_cancellation_emails")
      )

    assert [job] = jobs
    assert :ok = perform_job(EmailWorker, job.args)
  end

  test "the host cancelling the slot releases the held seat silently, with its expiry job", %{
    meeting: meeting,
    unverified: unverified
  } do
    {:ok, _held} =
      Guests.create_for_participant(meeting.id, unverified.id, ["held@example.com"])

    :ok = EmailVerificationJobs.schedule_seat_expiry(unverified)
    expiry = [worker: EmailVerificationExpiryWorker, args: %{"participant_id" => unverified.id}]
    assert_enqueued(expiry)

    reloaded = Repo.get!(MeetingSchema, meeting.id)
    assert {:ok, _cancelled} = Cancellation.cancel(reloaded, meeting.organizer_user_id, :none)

    assert {:ok, %{cancelled_at: %DateTime{}} = released} = ParticipantQueries.get(unverified.id)
    refute_enqueued(expiry)
    refute_enqueued(worker: EmailWorker, args: %{"participant_id" => unverified.id})
    assert {:error, :expired} = EmailVerification.verify_seat(released)
  end

  test "an unverified seat keeps a slot held, not live, once its last visible seat moves away", %{
    meeting: meeting,
    verified: verified,
    unverified: unverified
  } do
    new_params = %{
      date: Date.to_iso8601(Date.add(Date.utc_today(), 3)),
      time: "10:00",
      duration: "30min",
      user_timezone: "America/New_York"
    }

    assert {:ok, %{meeting: new_meeting}} =
             RescheduleSeat.execute(
               verified.management_token,
               new_params,
               meeting.organizer_user_id
             )

    assert new_meeting.id != meeting.id
    assert Repo.get!(MeetingSchema, meeting.id).status == :awaiting_verification
    assert {:ok, %{cancelled_at: nil}} = ParticipantQueries.get(unverified.id)
  end
end
