defmodule Tymeslot.Meetings.SeatHoldsTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Repo

  @capacity 3

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: @capacity)

    start_time =
      DateTime.utc_now()
      |> DateTime.add(5, :day)
      |> then(&%{&1 | hour: 10, minute: 0, second: 0, microsecond: {0, 0}})

    %{user: user, meeting_type: meeting_type, start_time: start_time}
  end

  defp attrs(ctx) do
    %{
      uid: UUID.generate(),
      title: ctx.meeting_type.name,
      start_time: ctx.start_time,
      end_time: DateTime.add(ctx.start_time, 30, :minute),
      duration: 30,
      status: :confirmed,
      organizer_user_id: ctx.user.id,
      organizer_name: "Organiser",
      organizer_email: "organiser@example.com",
      meeting_type_id: ctx.meeting_type.id
    }
  end

  defp request(email, guest_emails \\ []) do
    %{
      participant: %{
        name: "Booker #{email}",
        email: email,
        timezone: "Etc/UTC",
        locale: "en",
        custom_field_answers: %{}
      },
      guest_emails: guest_emails,
      max_participants: @capacity
    }
  end

  defp hold_opts(opts) do
    [hold: %{expires_at: DateTime.add(DateTime.utc_now(:second), 30, :minute)}] ++ opts
  end

  defp hold(ctx, email, guest_emails \\ [], opts \\ []),
    do: GroupScheduling.book_seat(attrs(ctx), request(email, guest_emails), hold_opts(opts))

  defp group_attrs(status) do
    start_time = DateTime.add(DateTime.utc_now(:second), 1, :day)

    %{
      uid: UUID.generate(),
      title: "Group",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      organizer_name: "Organiser",
      organizer_email: "organiser@example.com",
      capacity: 3,
      status: status
    }
  end

  defp book(ctx, email, opts \\ []),
    do: GroupScheduling.book_seat(attrs(ctx), request(email), opts)

  test "a hold creates an awaiting_payment meeting", ctx do
    assert {:ok, %{meeting: meeting, seat_hold: hold, created_meeting?: true} = booking} =
             hold(ctx, "ann@example.com")

    refute Map.has_key?(booking, :participant)
    assert meeting.status == :awaiting_payment
    assert Repo.get!(MeetingSchema, meeting.id).status == :awaiting_payment

    assert [%SeatHoldSchema{status: :held, seats: 1, meeting_id: meeting_id} = stored] =
             Repo.all(SeatHoldSchema)

    assert meeting_id == meeting.id
    assert stored.id == hold.id
    assert stored.email == "ann@example.com"
    assert stored.meeting_type_id == ctx.meeting_type.id
    assert stored.start_time == meeting.start_time
    assert Repo.all(ParticipantSchema) == []
    assert Repo.all(GuestSchema) == []
  end

  test "a hold snapshots its guests and counts them as seats", ctx do
    assert {:ok, %{seat_hold: hold}} =
             hold(ctx, "ann@example.com", ["g1@example.com", "g2@example.com"])

    assert hold.seats == 3

    assert Repo.get!(SeatHoldSchema, hold.id).guests == [
             %{"name" => nil, "email" => "g1@example.com"},
             %{"name" => nil, "email" => "g2@example.com"}
           ]
  end

  test "a hold joins a confirmed meeting without changing it", ctx do
    {:ok, %{meeting: meeting}} = book(ctx, "free@example.com")

    assert {:ok, %{meeting: joined, seat_hold: %SeatHoldSchema{}, created_meeting?: false}} =
             hold(ctx, "ann@example.com")

    assert joined.id == meeting.id
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed
  end

  test "a free seat on a meeting a hold created confirms it as a new slot", ctx do
    {:ok, %{meeting: meeting}} = hold(ctx, "ann@example.com")

    assert {:ok, %{meeting: joined, participant: _seat, created_meeting?: true}} =
             book(ctx, "free@example.com")

    assert joined.id == meeting.id
    assert joined.status == :confirmed
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed
    assert [%SeatHoldSchema{status: :held}] = Repo.all(SeatHoldSchema)
  end

  test "a second hold on a meeting a hold created leaves it awaiting payment", ctx do
    {:ok, %{meeting: meeting}} = hold(ctx, "ann@example.com")

    assert {:ok, %{created_meeting?: false}} = hold(ctx, "bob@example.com")
    assert Repo.get!(MeetingSchema, meeting.id).status == :awaiting_payment
  end

  test "an invalid :hold option is refused before anything is written", ctx do
    for bad <- [%{}, %{expires_at: "2026-12-01T10:00:00Z"}, :yes, %{expires_at: nil}] do
      assert {:error, :invalid_hold} =
               GroupScheduling.book_seat(attrs(ctx), request("ann@example.com"), hold: bad)
    end

    assert Repo.all(MeetingSchema) == []
    assert Repo.all(SeatHoldSchema) == []
  end

  test "a hold on a planned session leaves it confirmed", ctx do
    session =
      insert(:group_meeting,
        organizer_user_id: ctx.user.id,
        meeting_type_ref: ctx.meeting_type,
        start_time: ctx.start_time,
        end_time: DateTime.add(ctx.start_time, 30, :minute),
        capacity: @capacity,
        planned: true,
        status: :confirmed
      )

    assert {:ok, %{meeting: joined, created_meeting?: false}} =
             hold(ctx, "ann@example.com", [], join_only: true)

    assert joined.id == session.id
    assert Repo.get!(MeetingSchema, session.id).status == :confirmed
  end

  describe "capacity" do
    test "held seats count against capacity", ctx do
      {:ok, _hold} = hold(ctx, "ann@example.com", ["g1@example.com", "g2@example.com"])

      assert {:error, :slot_full} = book(ctx, "bob@example.com")
      assert {:error, :slot_full} = hold(ctx, "cat@example.com")
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    test "released seats are free again", ctx do
      {:ok, %{seat_hold: hold}} =
        hold(ctx, "ann@example.com", ["g1@example.com", "g2@example.com"])

      assert {:ok, %SeatHoldSchema{status: :released}} = SeatHolds.release(hold, :expired)

      assert {:ok, %{participant: %ParticipantSchema{}, created_meeting?: true}} =
               book(ctx, "bob@example.com")
    end

    test "a lapsed hold still counts until released", ctx do
      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)

      {:ok, _hold} =
        GroupScheduling.book_seat(
          attrs(ctx),
          request("ann@example.com", ["g1@example.com", "g2@example.com"]),
          hold: %{expires_at: past}
        )

      assert {:error, :slot_full} = book(ctx, "bob@example.com")
    end
  end

  describe "release/2" do
    test "is idempotent", ctx do
      {:ok, %{seat_hold: hold}} = hold(ctx, "ann@example.com")

      assert {:ok, %SeatHoldSchema{status: :released, released_reason: :abandoned}} =
               SeatHolds.release(hold, :abandoned)

      assert {:ok, :unchanged} = SeatHolds.release(hold, :expired)
      assert %SeatHoldSchema{released_reason: :abandoned} = SeatHolds.get(hold.id)
    end

    test "leaves a converted hold alone", ctx do
      {:ok, %{seat_hold: hold}} = hold(ctx, "ann@example.com")

      Repo.update_all(from(h in SeatHoldSchema, where: h.id == ^hold.id),
        set: [status: :converted]
      )

      assert {:ok, :unchanged} = SeatHolds.release(hold, :expired)
      assert %SeatHoldSchema{status: :converted} = SeatHolds.get(hold.id)
    end

    test "leaves the meeting's status alone", ctx do
      {:ok, %{meeting: meeting, seat_hold: hold}} = hold(ctx, "ann@example.com")

      {:ok, _released} = SeatHolds.release(hold, :expired)

      assert Repo.get!(MeetingSchema, meeting.id).status == :awaiting_payment
    end
  end

  describe "one seat per email" do
    # The email's checkout is still open, which is not a booking: the booker
    # is told so apart from an email that has a seat.
    test "a held email cannot book again", ctx do
      {:ok, _hold} = hold(ctx, "ann@example.com")

      assert {:error, :seat_held} = hold(ctx, "ANN@example.com")
      assert {:error, :seat_held} = book(ctx, "ANN@example.com")
      assert Repo.aggregate(SeatHoldSchema, :count) == 1
      assert Repo.all(ParticipantSchema) == []
    end

    test "a booked email cannot hold", ctx do
      {:ok, _seat} = book(ctx, "ann@example.com")

      assert {:error, :already_booked} = hold(ctx, "ann@example.com")
      assert Repo.all(SeatHoldSchema) == []
    end

    test "a released hold frees the email", ctx do
      {:ok, %{seat_hold: hold}} = hold(ctx, "ann@example.com")
      {:ok, _released} = SeatHolds.release(hold, :failed)

      assert {:ok, %{seat_hold: %SeatHoldSchema{}}} = hold(ctx, "ann@example.com")
    end
  end

  describe ":on_booked" do
    test "sees the hold", ctx do
      on_booked = fn booking ->
        refute Map.has_key?(booking, :participant)
        assert %{meeting: %MeetingSchema{}, created_meeting?: true} = booking
        {:ok, booking.seat_hold.id}
      end

      assert {:ok, %{seat_hold: hold, on_booked_result: result}} =
               hold(ctx, "ann@example.com", [], on_booked: on_booked)

      assert result == hold.id
    end

    test "an error rolls back the hold and its meeting", ctx do
      assert {:error, :boom} =
               hold(ctx, "ann@example.com", [], on_booked: fn _booking -> {:error, :boom} end)

      assert Repo.all(SeatHoldSchema) == []
      assert Repo.all(MeetingSchema) == []
    end
  end

  describe "topic/1 and broadcast/2" do
    test "deliver a hold's outcome to its subscribers" do
      hold_id = UUID.generate()
      participant_id = UUID.generate()
      :ok = Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold_id))

      :ok = SeatHolds.broadcast(hold_id, {:paid, participant_id})
      :ok = SeatHolds.broadcast(hold_id, :expired)

      assert_receive {:paid, ^participant_id}
      assert_receive :expired
      assert SeatHolds.topic(hold_id) == "seat_hold_payment:" <> hold_id
    end
  end

  describe "MeetingSchema.group_changeset/2" do
    test "honours awaiting_payment" do
      changeset = MeetingSchema.group_changeset(%MeetingSchema{}, group_attrs(:awaiting_payment))
      assert Changeset.get_field(changeset, :status) == :awaiting_payment
    end

    test "ignores other statuses" do
      for status <- [:cancelled, :pending, :awaiting_approval] do
        changeset = MeetingSchema.group_changeset(%MeetingSchema{}, group_attrs(status))
        assert Changeset.get_field(changeset, :status) == :confirmed
      end
    end
  end
end
