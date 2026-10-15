defmodule Tymeslot.Bookings.GroupBookingsPausedTest do
  @moduledoc """
  A host who loses access to group bookings (`:group_bookings_allowed`) keeps
  every booking already made on their group types, but those types take no
  new seats, neither the first on a slot nor a join, and the booking page
  stops offering them. Setting the limit back to one, or regaining access,
  lifts the pause. Core's own default checker never pauses anything.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :meeting_types
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.{Create, RescheduleSeat}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo

  defmodule DenyGroupBookingsChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :group_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  defmodule FailingChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :group_bookings_allowed), do: raise("checker down")
    def check_access(_user_id, _feature), do: :ok
  end

  setup :verify_on_exit!

  setup do
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      {:ok, []}
    end)

    user = insert(:user)
    profile = insert(:profile, user: user)
    _schedule = open_schedule_for(profile)

    venue = insert(:venue, user: user, name: "Main Hall")

    group_type =
      insert(:meeting_type,
        user: user,
        name: "Workshop",
        max_participants: 3,
        locations: [in_person_location([venue])]
      )

    solo_type = insert(:meeting_type, user: user, name: "Solo Call")

    params = %{
      date: Date.add(Date.utc_today(), 5),
      time: "10:00",
      duration: "30min",
      user_timezone: "Etc/UTC",
      organizer_user_id: user.id,
      meeting_type_id: group_type.id
    }

    # A seat taken while the host still had group bookings.
    {:ok, existing} = book(params, "first@example.com")

    %{
      user: user,
      group_type: group_type,
      solo_type: solo_type,
      params: params,
      existing: existing
    }
  end

  defp book(params, email) do
    Create.execute(params, %{"name" => "Booker", "email" => email, "message" => ""},
      skip_calendar_check: true
    )
  end

  defp live_emails(meeting) do
    meeting.id
    |> ParticipantQueries.list_live_for_meeting()
    |> Enum.map(& &1.email)
    |> Enum.sort()
  end

  describe "with Core's default checker" do
    test "a group type is offered and takes both a join and a new slot", ctx do
      assert Enum.any?(
               MeetingTypes.get_public_meeting_types(ctx.user.id),
               &(&1.id == ctx.group_type.id)
             )

      assert %{id: id} = MeetingTypes.find_by_slug(ctx.user.id, "workshop")
      assert id == ctx.group_type.id

      assert {:ok, joined} = book(ctx.params, "second@example.com")
      assert joined.id == ctx.existing.id

      assert {:ok, new_slot} = book(%{ctx.params | time: "11:00"}, "third@example.com")
      assert new_slot.id != ctx.existing.id
    end
  end

  describe "once the host has lost access to group bookings" do
    setup do
      setup_config(:tymeslot, :feature_access_checker, DenyGroupBookingsChecker)
    end

    test "the existing booking is left intact", ctx do
      assert Repo.get!(MeetingSchema, ctx.existing.id).status == "confirmed"
      assert live_emails(ctx.existing) == ["first@example.com"]
    end

    test "a join on the live slot is refused and adds no seat", ctx do
      assert {:error, :meeting_type_inactive} = book(ctx.params, "second@example.com")
      assert live_emails(ctx.existing) == ["first@example.com"]
    end

    test "a first seat on a new slot is refused and creates no meeting", ctx do
      assert {:error, :meeting_type_inactive} =
               book(%{ctx.params | time: "11:00"}, "third@example.com")

      assert [_only_the_existing_meeting] = Repo.all(MeetingSchema)
    end

    test "the booking page offers neither the listing nor the direct link", ctx do
      public_ids = Enum.map(MeetingTypes.get_public_meeting_types(ctx.user.id), & &1.id)

      assert ctx.solo_type.id in public_ids
      refute ctx.group_type.id in public_ids

      assert MeetingTypes.find_by_slug(ctx.user.id, "workshop") == nil
      assert MeetingTypes.find_by_slug(ctx.user.id, "solo-call").id == ctx.solo_type.id
    end

    test "a one-to-one type books as before", ctx do
      assert {:ok, %MeetingSchema{}} =
               book(
                 %{ctx.params | meeting_type_id: ctx.solo_type.id, time: "12:00"},
                 "solo@example.com"
               )
    end

    test "setting the limit back to one lifts the pause", ctx do
      {:ok, one_to_one} =
        MeetingTypes.update_meeting_type(ctx.group_type, %{max_participants: 1})

      assert MeetingTypes.find_by_slug(ctx.user.id, "workshop").id == one_to_one.id

      assert {:ok, %MeetingSchema{id: id}} =
               book(%{ctx.params | time: "13:00"}, "again@example.com")

      assert id != ctx.existing.id
    end

    test "regaining access lifts the pause", ctx do
      setup_config(:tymeslot, :feature_access_checker, Tymeslot.Features.DefaultAccessChecker)

      assert {:ok, joined} = book(ctx.params, "second@example.com")
      assert joined.id == ctx.existing.id
    end

    # Moving a seat is part of the booking already made, not a new one: the
    # participant keeps their seat-management link, so a seat on a paused
    # type can still move (or be cancelled) without the host's plan being
    # their problem.
    test "an existing seat can still be moved", ctx do
      [seat] = ParticipantQueries.list_live_for_meeting(ctx.existing.id)

      assert {:ok, %{meeting: moved_to}} =
               RescheduleSeat.execute(
                 seat.management_token,
                 %{
                   date: Date.to_iso8601(ctx.params.date),
                   time: "15:00",
                   duration: "30min",
                   user_timezone: "Etc/UTC"
                 },
                 ctx.user.id
               )

      assert live_emails(moved_to) == ["first@example.com"]
    end
  end

  @tag :capture_log
  test "a checker that fails counts as no access", ctx do
    setup_config(:tymeslot, :feature_access_checker, FailingChecker)

    assert {:error, :meeting_type_inactive} = book(ctx.params, "second@example.com")
    assert MeetingTypes.find_by_slug(ctx.user.id, "workshop") == nil
  end
end
