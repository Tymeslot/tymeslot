defmodule Tymeslot.Availability.OfferSeatMoveTest do
  @moduledoc """
  What the seat-move booking page offers around the seat's own meeting.

  `RescheduleSeat` lets a seat move onto a time overlapping its own meeting
  only when the mover is that meeting's last live seat, since the move then
  cancels the old meeting in the same transaction. The page has to offer by
  the same rule (display == bookable): the overlapping time is offered and
  books for the sole seat, and is neither offered nor bookable while another
  seat keeps the old meeting going. The old meeting's event on the host's
  calendar, as Tymeslot wrote it there, is treated the same way.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.{Create, RescheduleSeat}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @timezone "Etc/UTC"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    stub_calendar_events([])
    AvailabilityCache.clear_all()

    %{user: user, profile: profile} = create_always_bookable_profile(timezone: @timezone)
    venue = insert(:venue, user: user, name: "Main Hall")

    # An hour-long group type offered every half hour, so 2:30 PM is an
    # offered start overlapping the second half of a 2:00 PM meeting.
    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 60,
        slot_interval_minutes: 30,
        max_participants: 3,
        locations: [in_person_location([venue])]
      )

    date = Date.add(Date.utc_today(), 5)

    params = %{
      date: date,
      time: "2:00 PM",
      duration: "60min",
      user_timezone: @timezone,
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    {:ok, meeting} = book(params, "mover@example.com")
    [mover] = ParticipantQueries.list_live_for_meeting(meeting.id)

    # The host's calendar holds the meeting's own event from here on.
    stub_calendar_events([
      %{
        uid: meeting.calendar_uid,
        summary: "Workshop",
        start_time: meeting.start_time,
        end_time: meeting.end_time
      }
    ])

    %{
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      date: date,
      params: params,
      meeting: meeting,
      mover: mover
    }
  end

  defp stub_calendar_events(events) do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      {:ok, events}
    end)
  end

  defp book(params, email) do
    Create.execute(params, %{"name" => "Booker", "email" => email, "message" => ""})
  end

  defp offered_times(ctx, seat_token) do
    request = %{
      profile: ctx.profile,
      user_timezone: @timezone,
      meeting_type: ctx.meeting_type,
      reschedule_seat_token: seat_token
    }

    {:ok, slots} = Offer.slots_for_date(request, Date.to_iso8601(ctx.date), "60min")
    Enum.map(slots, & &1.time)
  end

  defp move_to(ctx, time) do
    RescheduleSeat.execute(
      ctx.mover.management_token,
      %{
        date: Date.to_iso8601(ctx.date),
        time: time,
        duration: "60min",
        user_timezone: @timezone
      },
      ctx.user.id
    )
  end

  test "the seat's only meeting does not block it: the overlap is offered and books", ctx do
    offered = offered_times(ctx, ctx.mover.management_token)

    assert "2:30 PM" in offered

    # Anchor: a page that is not moving this seat sees the meeting as busy.
    refute "2:30 PM" in offered_times(ctx, nil)

    assert {:ok, %{meeting: moved_to}} = move_to(ctx, "2:30 PM")
    assert DateTime.diff(moved_to.start_time, ctx.meeting.start_time, :minute) == 30
    assert Repo.get!(MeetingSchema, ctx.meeting.id).status == "cancelled"
  end

  test "with another seat on the meeting the overlap is neither offered nor bookable", ctx do
    {:ok, joined} = book(ctx.params, "stayer@example.com")
    assert joined.id == ctx.meeting.id

    refute "2:30 PM" in offered_times(ctx, ctx.mover.management_token)

    # Anchor: the page still offers the seat a time clear of its meeting.
    assert "4:00 PM" in offered_times(ctx, ctx.mover.management_token)

    assert {:error, :slot_taken} = move_to(ctx, "2:30 PM")
    assert Repo.get!(MeetingSchema, ctx.meeting.id).status == "confirmed"
    assert length(ParticipantQueries.list_live_for_meeting(ctx.meeting.id)) == 2
  end

  test "only the seat's own organiser's page leaves its meeting out", ctx do
    %{user: other_user} = create_always_bookable_profile(timezone: @timezone)

    assert %MeetingSchema{id: id} =
             RescheduleSeat.vacated_meeting(ctx.mover.management_token, ctx.user.id)

    assert id == ctx.meeting.id
    assert RescheduleSeat.vacated_meeting(ctx.mover.management_token, other_user.id) == nil
  end
end
