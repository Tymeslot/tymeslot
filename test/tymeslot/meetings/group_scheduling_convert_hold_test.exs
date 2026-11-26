defmodule Tymeslot.Meetings.GroupSchedulingConvertHoldTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers, only: [setup_config: 2]
  import Tymeslot.Factory
  import Tymeslot.StripeConnectTestHelpers, only: [enable_meeting_payments: 1]

  alias Ecto.Changeset
  alias Tymeslot.Bookings.CreateGroup
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Repo

  setup :enable_meeting_payments

  setup do
    # A slot rebuilt for a late payment asks for the type's calendar; these
    # hosts have none.
    Mox.stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    user = insert(:user)
    _profile = insert(:profile, user: user)

    meeting_type =
      insert(:meeting_type,
        user: user,
        max_participants: 4,
        payment_required: true,
        price_cents: 2000
      )

    # A late payment takes a new meeting only on a type taking payments now.
    insert(:connect_account, user: user, default_currency: "eur", charges_enabled: true)

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

  defp convert(hold) do
    Repo.transaction(fn ->
      GroupScheduling.convert_hold(hold.id, new_slot: fn _hold, _meeting -> :none end)
    end)
  end

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

  describe "a lapsed hold whose type would not take the booking now" do
    defmodule DenyGroupBookingsChecker do
      @moduledoc false
      @behaviour Tymeslot.Features.CheckerBehaviour

      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :group_bookings_allowed), do: {:error, :insufficient_plan}
      def check_access(_user_id, _feature), do: :ok
    end

    defmodule DenyMeetingPaymentsChecker do
      @moduledoc false
      @behaviour Tymeslot.Features.CheckerBehaviour

      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :meeting_payments), do: {:error, :insufficient_plan}
      def check_access(_user_id, _feature), do: :ok
    end

    setup ctx do
      lapsed = slot(ctx, status: :expired)

      hold =
        insert(:seat_hold,
          meeting: lapsed,
          email: "late@example.com",
          status: :released,
          released_reason: :expired
        )

      %{hold: hold}
    end

    for {case_name, change} <- [
          {"deactivated", [is_active: false]},
          {"no longer paid", [payment_required: false]},
          {"no longer a group type", [max_participants: 1]}
        ] do
      test "is refused on a type #{case_name}", ctx do
        ctx.meeting_type |> Changeset.change(unquote(change)) |> Repo.update!()
        assert_refused(ctx.hold)
      end
    end

    test "is refused on a paused group type", ctx do
      setup_config(:tymeslot, feature_access_checker: DenyGroupBookingsChecker)
      assert_refused(ctx.hold)
    end

    # The payment has already been taken: refusing the seat would only hand
    # it back, so losing the means to take a new one does not.
    test "still books once its host's Stripe account is gone", ctx do
      Repo.delete_all(ConnectAccountSchema)
      assert_booked(ctx.hold)
    end

    test "still books once its host's plan no longer takes payments", ctx do
      setup_config(:tymeslot, feature_access_checker: DenyMeetingPaymentsChecker)
      assert_booked(ctx.hold)
    end

    test "is refused once its slot has started", ctx do
      past = DateTime.add(DateTime.utc_now(:second), -3600, :second)

      Repo.update_all(MeetingSchema,
        set: [start_time: past, end_time: DateTime.add(past, 30, :minute)]
      )

      assert_refused(ctx.hold)
    end

    defp assert_booked(hold) do
      assert {:ok, {:ok, booking}} =
               Repo.transaction(fn -> CreateGroup.complete_paid_hold(hold.id) end)

      assert booking.created_meeting?
      assert %{status: :converted} = SeatHolds.get(hold.id)
      assert Repo.get!(MeetingSchema, booking.meeting.id).status == :confirmed
    end

    defp assert_refused(hold) do
      assert {:ok, {:refused, :slot_full}} =
               Repo.transaction(fn -> CreateGroup.complete_paid_hold(hold.id) end)

      assert %{status: :released, participant_id: nil} = SeatHolds.get(hold.id)
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end
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

    assert {:ok, {:refused, :slot_full}} =
             Repo.transaction(fn -> CreateGroup.complete_paid_hold(hold.id) end)

    assert %{status: :released, released_reason: :expired, participant_id: nil} =
             SeatHolds.get(hold.id)

    assert length(ParticipantQueries.list_live_for_meeting(full.id)) == 2
    assert Repo.aggregate(MeetingSchema, :count) == 2
  end

  test "a hold on a cancelled meeting is never converted", ctx do
    meeting = slot(ctx, status: :cancelled)
    hold = insert(:seat_hold, meeting: meeting, email: "payer@example.com")

    assert {:ok, {:refused, :hold_not_convertible}} = convert(hold)
    assert SeatHolds.get(hold.id).status == :held
    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
  end

  describe "a lapsed hold whose meeting was cancelled" do
    setup ctx do
      meeting = slot(ctx, status: :confirmed)
      participant = insert(:participant, meeting: meeting, email: "seated@example.com")

      hold =
        insert(:seat_hold,
          meeting: meeting,
          email: "late@example.com",
          status: :released,
          released_reason: :expired
        )

      %{meeting: meeting, participant: participant, hold: hold}
    end

    test "converts onto its slot when the meeting emptied", ctx do
      {:ok, _left} = ParticipantQueries.cancel(ctx.participant)
      assert {:ok, :meeting_cancelled} = SeatRelease.release(ctx.meeting)

      assert {:ok, {:ok, booking}} =
               Repo.transaction(fn -> CreateGroup.complete_paid_hold(ctx.hold.id) end)

      assert booking.created_meeting?
      assert booking.meeting.id != ctx.meeting.id
      assert booking.meeting.start_time == ctx.start_time
      assert Repo.get!(MeetingSchema, booking.meeting.id).status == :confirmed
      assert SeatHolds.get(ctx.hold.id).status == :converted
    end

    test "is refused when its host cancelled it", ctx do
      ctx.meeting |> Changeset.change(status: :cancelled) |> Repo.update!()
      assert_not_convertible(ctx.hold)
    end

    test "is refused when its host cancelled it with only holds left on it", ctx do
      {:ok, _left} = ParticipantQueries.cancel(ctx.participant)

      insert(:seat_hold,
        meeting: ctx.meeting,
        email: "other@example.com",
        status: :released,
        released_reason: :meeting_cancelled
      )

      ctx.meeting |> Changeset.change(status: :cancelled) |> Repo.update!()
      assert_not_convertible(ctx.hold)
    end

    test "is refused on a planned session, which never empties", ctx do
      {:ok, _left} = ParticipantQueries.cancel(ctx.participant)

      ctx.meeting
      |> Changeset.change(status: :cancelled, planned: true)
      |> Repo.update!()

      assert_not_convertible(ctx.hold)
    end

    defp assert_not_convertible(hold) do
      assert {:ok, {:refused, :hold_not_convertible}} =
               Repo.transaction(fn -> CreateGroup.complete_paid_hold(hold.id) end)

      assert Repo.aggregate(MeetingSchema, :count) == 1
    end
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

    assert {:ok, {:refused, :hold_not_convertible}} =
             Repo.transaction(fn -> CreateGroup.complete_paid_hold(hold.id) end)

    assert Repo.aggregate(MeetingSchema, :count) == 1
  end

  test "a converted hold is not converted again", ctx do
    meeting = slot(ctx, status: :awaiting_payment)
    hold = insert(:seat_hold, meeting: meeting, email: "payer@example.com")

    assert {:ok, {:ok, _booking}} = convert(hold)
    assert {:ok, {:refused, :hold_not_convertible}} = convert(hold)
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

  describe "a planned session whose registration has closed" do
    setup ctx do
      session =
        slot(ctx,
          status: :confirmed,
          planned: true,
          registration_closes_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)
        )

      %{session: session}
    end

    test "still converts a hold held on it, which reserved its seats before the close", ctx do
      hold = insert(:seat_hold, meeting: ctx.session, email: "early@example.com")

      assert {:ok, {:ok, booking}} = convert(hold)
      assert booking.meeting.id == ctx.session.id

      assert [%{email: "early@example.com"}] =
               ParticipantQueries.list_live_for_meeting(ctx.session.id)

      assert SeatHolds.get(hold.id).status == :converted
    end

    test "refuses a hold that had lapsed, as any booking after the close", ctx do
      hold =
        insert(:seat_hold,
          meeting: ctx.session,
          email: "late@example.com",
          status: :released,
          released_reason: :expired
        )

      assert {:ok, {:refused, :slot_full}} = convert(hold)
      assert %{status: :released, released_reason: :expired} = SeatHolds.get(hold.id)
      assert ParticipantQueries.list_live_for_meeting(ctx.session.id) == []
    end
  end

  test "a lapsed hold joins the live meeting now at its slot, bringing its language's texts",
       ctx do
    texts = %{
      "de" => %{"meeting_type" => "Gruppenkurs"},
      "fr" => %{"meeting_type" => "Cours collectif"}
    }

    lapsed =
      slot(ctx,
        status: :expired,
        meeting_type: "Group Class",
        description: "A class",
        attendee_texts: texts
      )

    live = slot(ctx, status: :confirmed, meeting_type: "Group Class", description: "A class")
    insert(:participant, meeting: live, email: "seated@example.com")

    hold =
      insert(:seat_hold,
        meeting: lapsed,
        email: "late@example.com",
        locale: "de",
        status: :released,
        released_reason: :expired
      )

    assert {:ok, {:ok, booking}} =
             Repo.transaction(fn -> CreateGroup.complete_paid_hold(hold.id) end)

    assert booking.meeting.id == live.id
    refute booking.created_meeting?
    assert length(ParticipantQueries.list_live_for_meeting(live.id)) == 2

    assert Repo.get!(MeetingSchema, live.id).attendee_texts == %{
             "de" => %{"meeting_type" => "Gruppenkurs"}
           }
  end
end
