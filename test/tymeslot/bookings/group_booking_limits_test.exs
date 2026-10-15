defmodule Tymeslot.Bookings.GroupBookingLimitsTest do
  @moduledoc """
  Booking limits on a group meeting type.

  A limit counts meeting rows. A seat on a live group slot adds none, so once
  a slot exists it stays offered and joinable however full the host's day is;
  a booking that would create another slot is still counted, whether it comes
  from the booking page or from a seat move.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :availability
  @moduletag :integration

  import Ecto.Query
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.CalendarCheck
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.RescheduleSeat
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @timezone "Etc/UTC"

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()

    %{user: user, profile: profile} = create_always_bookable_profile(timezone: @timezone)

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        max_participants: 10,
        max_bookings_per_day: 1
      )

    date = Date.add(Date.utc_today(), 5)

    {:ok, meeting} = book(user, meeting_type, date, "10:00", "first@example.com")

    %{user: user, profile: profile, meeting_type: meeting_type, date: date, meeting: meeting}
  end

  describe "a group slot on a day at its cap" do
    test "stays offered, and later bookers join it", ctx do
      assert %{seats_left: 9, capacity: 10} = offered_slot(ctx, "10:00 AM")

      assert {:ok, second} = book(ctx, "10:00", "second@example.com")
      assert second.id == ctx.meeting.id
      assert %{seats_left: 8} = offered_slot(ctx, "10:00 AM")

      assert {:ok, third} = book(ctx, "10:00", "third@example.com")
      assert third.id == ctx.meeting.id

      assert ctx.meeting.id
             |> ParticipantQueries.list_live_for_meeting()
             |> Enum.map(& &1.email)
             |> Enum.sort() == ["first@example.com", "second@example.com", "third@example.com"]
    end

    test "keeps its day offered in the month view", ctx do
      AvailabilityCache.clear_all()

      assert {:ok, %{} = days} =
               Offer.days_in_range(request(ctx), ctx.date, ctx.date, 30)

      assert Map.fetch!(days, Date.to_iso8601(ctx.date))
    end

    test "leaves every other time that day closed", ctx do
      assert offered_slot(ctx, "11:00 AM") == nil

      assert {:error, :booking_limit_reached} = book(ctx, "11:00", "other@example.com")
      assert meetings_on(ctx.date) == [ctx.meeting.id]
    end
  end

  describe "the join exemption" do
    # The pre-check exempts the booking because the slot has a seat for it;
    # by the time the seat transaction runs, someone else has taken that
    # seat. The booking must be refused as full, never turned into a new
    # slot past the cap.
    test "does not outlive the seat it was granted for", %{user: user} do
      pair_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          max_participants: 2,
          max_bookings_per_day: 1
        )

      date = Date.add(Date.utc_today(), 8)
      {:ok, meeting} = book(user, pair_type, date, "10:00", "first@example.com")

      result =
        with_hook_before_calendar_check(
          fn -> {:ok, _fast} = book(user, pair_type, date, "10:00", "fast@example.com") end,
          fn -> book(user, pair_type, date, "10:00", "slow@example.com") end
        )

      assert {:error, :slot_taken} = result
      assert meetings_on(date) == [meeting.id]
      assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
    end
  end

  describe "a seat move" do
    setup ctx do
      {:ok, old_meeting} =
        book(ctx, Date.add(ctx.date, 1), "10:00", "mover@example.com")

      [mover] = ParticipantQueries.list_live_for_meeting(old_meeting.id)
      %{old_meeting: old_meeting, mover: mover}
    end

    test "into a new slot on a day at its cap is refused", ctx do
      assert {:error, :booking_limit_reached} =
               RescheduleSeat.execute(
                 ctx.mover.management_token,
                 move_params(ctx.date, "11:00"),
                 ctx.user.id
               )

      assert [%{id: id}] = ParticipantQueries.list_live_for_meeting(ctx.old_meeting.id)
      assert id == ctx.mover.id
      assert meetings_on(ctx.date) == [ctx.meeting.id]
    end

    test "onto the existing slot of a day at its cap joins it", ctx do
      assert {:ok, %{meeting: joined, created_meeting?: false}} =
               RescheduleSeat.execute(
                 ctx.mover.management_token,
                 move_params(ctx.date, "10:00"),
                 ctx.user.id
               )

      assert joined.id == ctx.meeting.id
      assert ParticipantQueries.list_live_for_meeting(ctx.old_meeting.id) == []
    end
  end

  defp book(%{user: user, meeting_type: meeting_type, date: date}, time, email),
    do: book(user, meeting_type, date, time, email)

  defp book(%{user: user, meeting_type: meeting_type}, %Date{} = date, time, email),
    do: book(user, meeting_type, date, time, email)

  defp book(user, meeting_type, date, time, email) do
    Create.execute(
      %{
        date: date,
        time: time,
        duration: "30min",
        user_timezone: @timezone,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      },
      %{"name" => "Booker #{email}", "email" => email, "message" => ""}
    )
  end

  defp move_params(date, time) do
    %{date: Date.to_iso8601(date), time: time, duration: "30min", user_timezone: @timezone}
  end

  defp request(%{profile: profile, meeting_type: meeting_type}),
    do: %{profile: profile, user_timezone: @timezone, meeting_type: meeting_type}

  defp offered_slot(ctx, time) do
    AvailabilityCache.clear_all()

    {:ok, slots} = Offer.slots_for_date(request(ctx), Date.to_iso8601(ctx.date), 30)

    Enum.find(slots, &(&1.time == time))
  end

  defp meetings_on(date) do
    from_utc = DateTime.new!(date, ~T[00:00:00], @timezone)
    to_utc = DateTime.add(from_utc, 1, :day)

    MeetingSchema
    |> where([m], m.status == "confirmed")
    |> where([m], m.start_time >= ^from_utc and m.start_time < ^to_utc)
    |> select([m], m.id)
    |> Repo.all()
  end

  # Runs `hook` once, at the submit's calendar check: after the booking's
  # pre-checks have passed and before its seat transaction starts.
  defp with_hook_before_calendar_check(hook, fun) do
    :meck.new(CalendarCheck, [:passthrough])

    :meck.expect(CalendarCheck, :enforce, fn slot, config, opts ->
      if Process.get(:hook_ran) != true do
        Process.put(:hook_ran, true)
        hook.()
      end

      :meck.passthrough([slot, config, opts])
    end)

    try do
      fun.()
    after
      :meck.unload(CalendarCheck)
    end
  end
end
