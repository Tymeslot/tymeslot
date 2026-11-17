defmodule Tymeslot.Meetings.GroupSchedulingConvertHoldTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Bookings.CreateGroup
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Repo

  setup do
    # A slot rebuilt for a late payment asks for the type's calendar; these
    # hosts have none.
    Mox.stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 4)

    start_time =
      DateTime.utc_now()
      |> DateTime.add(5, :day)
      |> then(&%{&1 | hour: 10, minute: 0, second: 0, microsecond: {0, 0}})

    %{user: user, meeting_type: meeting_type, start_time: start_time}
  end

  defp slot(ctx, attrs) do
    insert(
      :group_meeting,
      Keyword.merge(
        [
          organizer_user: ctx.user,
          meeting_type_ref: ctx.meeting_type,
          title: ctx.meeting_type.name,
          start_time: ctx.start_time,
          end_time: DateTime.add(ctx.start_time, 30, :minute),
          duration: 30,
          capacity: 4
        ],
        attrs
      )
    )
  end

  defp convert(hold), do: Repo.transaction(fn -> GroupScheduling.convert_hold(hold.id) end)

  test "converting the first hold confirms the meeting and reports it as new", ctx do
    meeting = slot(ctx, status: :awaiting_payment)

    hold =
      insert(:seat_hold,
        meeting: meeting,
        seats: 2,
        email: "payer@example.com",
        guests: [%{"name" => nil, "email" => "guest@example.com"}]
      )

    assert {:ok, {:ok, booking}} = convert(hold)
    assert booking.created_meeting?
    assert booking.meeting.id == meeting.id
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant.id == booking.participant.id
    assert participant.email == "payer@example.com"
    assert ["guest@example.com"] = Enum.map(GuestQueries.list_for_meeting(meeting.id), & &1.email)

    converted = SeatHolds.get(hold.id)
    assert converted.status == :converted
    assert converted.participant_id == participant.id
  end

  test "converting into a confirmed meeting joins it", ctx do
    meeting = slot(ctx, status: :confirmed)
    insert(:participant, meeting: meeting, email: "first@example.com")
    hold = insert(:seat_hold, meeting: meeting, email: "payer@example.com")

    assert {:ok, {:ok, booking}} = convert(hold)
    refute booking.created_meeting?
    assert booking.meeting.id == meeting.id
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
  end

  test "a lapsed hold converts while the slot has room", ctx do
    meeting = slot(ctx, status: :expired)

    hold =
      insert(:seat_hold,
        meeting: meeting,
        email: "late@example.com",
        status: :released,
        released_reason: :expired
      )

    assert {:ok, {:ok, booking}} =
             Repo.transaction(fn -> CreateGroup.complete_paid_hold(hold.id) end)

    assert booking.created_meeting?
    assert booking.meeting.id != meeting.id
    assert booking.meeting.start_time == ctx.start_time

    new_meeting = Repo.get!(MeetingSchema, booking.meeting.id)
    assert new_meeting.status == :confirmed
    assert new_meeting.meeting_type_id == ctx.meeting_type.id
    assert new_meeting.capacity == 4

    assert [%{email: "late@example.com"}] =
             ParticipantQueries.list_live_for_meeting(new_meeting.id)

    assert %{status: :converted, released_reason: nil} = SeatHolds.get(hold.id)
  end

  test "a lapsed hold is refused when the slot filled meanwhile", ctx do
    lapsed = slot(ctx, status: :expired)
    full = slot(ctx, status: :confirmed, capacity: 2)
    insert(:participant, meeting: full, email: "one@example.com")
    insert(:participant, meeting: full, email: "two@example.com")

    hold =
      insert(:seat_hold,
        meeting: lapsed,
        email: "late@example.com",
        status: :released,
        released_reason: :expired
      )

    assert {:ok, {:error, :slot_full}} =
             Repo.transaction(fn -> CreateGroup.complete_paid_hold(hold.id) end)

    assert %{status: :released, released_reason: :expired, participant_id: nil} =
             SeatHolds.get(hold.id)

    assert length(ParticipantQueries.list_live_for_meeting(full.id)) == 2
    assert Repo.aggregate(MeetingSchema, :count) == 2
  end

  test "a hold on a cancelled meeting is never converted", ctx do
    meeting = slot(ctx, status: :cancelled)
    hold = insert(:seat_hold, meeting: meeting, email: "payer@example.com")

    assert {:ok, {:error, :hold_not_convertible}} = convert(hold)
    assert SeatHolds.get(hold.id).status == :held
    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
  end

  test "a hold released with its cancelled meeting is never converted", ctx do
    meeting = slot(ctx, status: :expired)

    hold =
      insert(:seat_hold,
        meeting: meeting,
        email: "payer@example.com",
        status: :released,
        released_reason: :meeting_cancelled
      )

    assert {:ok, {:error, :hold_not_convertible}} =
             Repo.transaction(fn -> CreateGroup.complete_paid_hold(hold.id) end)

    assert Repo.aggregate(MeetingSchema, :count) == 1
  end

  test "a converted hold is not converted again", ctx do
    meeting = slot(ctx, status: :awaiting_payment)
    hold = insert(:seat_hold, meeting: meeting, email: "payer@example.com")

    assert {:ok, {:ok, _booking}} = convert(hold)
    assert {:ok, {:error, :hold_not_convertible}} = convert(hold)
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 1
  end

  test "a converting hold does not count against itself", ctx do
    meeting = slot(ctx, status: :awaiting_payment, capacity: 2)

    hold =
      insert(:seat_hold,
        meeting: meeting,
        seats: 2,
        email: "payer@example.com",
        guests: [%{"name" => nil, "email" => "guest@example.com"}]
      )

    assert {:ok, {:ok, booking}} = convert(hold)
    assert booking.meeting.id == meeting.id
    assert SeatHolds.seats_held(meeting.id) == 0
  end
end
