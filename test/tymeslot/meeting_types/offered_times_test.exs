defmodule Tymeslot.MeetingTypes.OfferedTimesTest do
  @moduledoc """
  The offered times of a one-to-one meeting type with fixed dates: who may
  add and remove them, what is refused, and what the rest of the type's
  rules make of them (the mode switch, the public listing, retention).
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.{FixedDates, OfferedTimes, OfferedTimeSchema}
  alias Tymeslot.Repo

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user)

    # A single venue, so the type may also become a group type.
    venue = insert(:venue, user: user)

    meeting_type =
      insert(:meeting_type,
        user: user,
        max_participants: 1,
        fixed_dates: true,
        is_active: true,
        locations: [in_person_location([venue])]
      )

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  defp in_days(days), do: DateTime.add(DateTime.utc_now(:second), days, :day)

  describe "add/4" do
    test "stores the instant in UTC, to the second", %{user: user, meeting_type: type} do
      starts_at =
        in_days(3) |> DateTime.shift_zone!("Asia/Tokyo") |> Map.put(:microsecond, {5, 6})

      assert {:ok, offered} = OfferedTimes.add(type, user.id, starts_at)

      assert offered.starts_at.time_zone == "Etc/UTC"
      assert DateTime.compare(offered.starts_at, DateTime.truncate(starts_at, :second)) == :eq
      assert [%{id: id}] = OfferedTimes.list(type)
      assert id == offered.id
    end

    test "refuses another host's type", %{meeting_type: type} do
      stranger = insert(:user)

      assert {:error, :not_found} = OfferedTimes.add(type, stranger.id, in_days(3))
      assert OfferedTimes.list(type) == []
    end

    test "refuses a group type and a type without fixed dates", %{user: user} do
      group = insert(:meeting_type, user: user, max_participants: 5, fixed_dates: true)
      plain = insert(:meeting_type, user: user, max_participants: 1, fixed_dates: false)

      assert {:error, :not_fixed_dates} = OfferedTimes.add(group, user.id, in_days(3))
      assert {:error, :not_fixed_dates} = OfferedTimes.add(plain, user.id, in_days(3))
    end

    test "refuses a time in the past and one already offered", %{user: user, meeting_type: type} do
      assert {:error, :start_in_past} = OfferedTimes.add(type, user.id, in_days(-1))

      starts_at = in_days(3)
      {:ok, _first} = OfferedTimes.add(type, user.id, starts_at)
      assert {:error, :duplicate} = OfferedTimes.add(type, user.id, starts_at)
      assert length(OfferedTimes.list(type)) == 1
    end

    test "refuses more than the cap", %{user: user, meeting_type: type} do
      now = DateTime.utc_now(:second)

      rows =
        for n <- 1..OfferedTimes.max_per_type() do
          %{
            meeting_type_id: type.id,
            starts_at: DateTime.add(now, n, :hour),
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(OfferedTimeSchema, rows)

      assert {:error, :too_many} = OfferedTimes.add(type, user.id, in_days(30))
    end
  end

  describe "delete/3" do
    test "removes the owner's time", %{user: user, meeting_type: type} do
      {:ok, offered} = OfferedTimes.add(type, user.id, in_days(3))

      assert {:ok, _deleted} = OfferedTimes.delete(type, user.id, to_string(offered.id))
      assert OfferedTimes.list(type) == []
    end

    test "refuses another host, and a time of another type", %{user: user, meeting_type: type} do
      {:ok, offered} = OfferedTimes.add(type, user.id, in_days(3))
      stranger = insert(:user)
      other = insert(:meeting_type, user: user, max_participants: 1, fixed_dates: true)

      assert {:error, :not_found} = OfferedTimes.delete(type, stranger.id, offered.id)
      assert {:error, :not_found} = OfferedTimes.delete(other, user.id, offered.id)
      assert {:error, :not_found} = OfferedTimes.delete(type, user.id, "not-an-id")
      assert [_still_there] = OfferedTimes.list(type)
    end
  end

  describe "the mode switch" do
    test "refuses making a type with upcoming offered times a group type", ctx do
      {:ok, _offered} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, in_days(3))

      assert {:error, changeset} =
               MeetingTypes.update_meeting_type(ctx.meeting_type, %{max_participants: 5})

      assert {"remove the offered times before turning group bookings on", _opts} =
               changeset.errors[:max_participants]

      assert Repo.reload!(ctx.meeting_type).max_participants == 1
    end

    test "lets the type become a group type once its times are removed", ctx do
      {:ok, offered} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, in_days(3))
      {:ok, _deleted} = OfferedTimes.delete(ctx.meeting_type, ctx.user.id, offered.id)

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type(ctx.meeting_type, %{max_participants: 5})

      assert FixedDates.sessions?(updated)
    end

    test "refuses a group type with fixed dates off too, so times cannot be buried", ctx do
      {:ok, _offered} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, in_days(3))
      {:ok, dormant} = MeetingTypes.update_meeting_type(ctx.meeting_type, %{fixed_dates: false})

      assert {:error, changeset} =
               MeetingTypes.update_meeting_type(dormant, %{max_participants: 5})

      assert {"remove the offered times before turning group bookings on", _opts} =
               changeset.errors[:max_participants]

      assert Repo.reload!(ctx.meeting_type).max_participants == 1
    end

    test "turning fixed dates off keeps the times, unused", ctx do
      {:ok, _offered} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, in_days(3))

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type(ctx.meeting_type, %{fixed_dates: false})

      refute FixedDates.offered_times?(updated)
      assert OfferedTimes.starts_for(updated) == nil
      assert [_kept] = OfferedTimes.list(updated)
    end
  end

  describe "the public listing" do
    test "leaves out a one-to-one fixed type with no upcoming time", ctx do
      plain = insert(:meeting_type, user: ctx.user, max_participants: 1, is_active: true)

      ids = fn -> ctx.user.id |> MeetingTypes.get_public_meeting_types() |> Enum.map(& &1.id) end

      assert ids.() == [plain.id]

      {:ok, _offered} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, in_days(3))

      assert Enum.sort(ids.()) == Enum.sort([plain.id, ctx.meeting_type.id])
    end
  end

  describe "the booking rules' reach" do
    # Six hours' notice and a seven-day window, on the type's own schedule.
    setup ctx do
      schedule =
        insert(:availability_schedule,
          profile: ctx.profile,
          min_advance_hours: 6,
          advance_booking_days: 7
        )

      type =
        insert(:meeting_type,
          user: ctx.user,
          max_participants: 1,
          fixed_dates: true,
          is_active: true,
          availability_schedule_id: schedule.id
        )

      %{type: type}
    end

    test "names each time's status, and counts only a bookable one as next",
         %{type: type} = ctx do
      now = DateTime.utc_now(:second)
      {:ok, too_soon} = OfferedTimes.add(type, ctx.user.id, DateTime.add(now, 2, :hour))
      {:ok, too_far} = OfferedTimes.add(type, ctx.user.id, DateTime.add(now, 12, :day))

      assert OfferedTimes.list_with_status(type, now) == [
               {too_soon, :too_soon},
               {too_far, :too_far}
             ]

      assert OfferedTimes.next_by_type([type], now) == %{type.id => nil}

      {:ok, open} = OfferedTimes.add(type, ctx.user.id, DateTime.add(now, 3, :day))

      assert {^open, :bookable} = Enum.at(OfferedTimes.list_with_status(type, now), 1)
      assert OfferedTimes.next_by_type([type], now) == %{type.id => open.starts_at}
    end

    test "reads the type's own notice and window over its schedule's", ctx do
      now = DateTime.utc_now(:second)

      type =
        insert(:meeting_type,
          user: ctx.user,
          max_participants: 1,
          fixed_dates: true,
          availability_schedule_id: ctx.type.availability_schedule_id,
          min_advance_hours: 0,
          advance_booking_days: 30
        )

      {:ok, soon} = OfferedTimes.add(type, ctx.user.id, DateTime.add(now, 2, :hour))
      {:ok, far} = OfferedTimes.add(type, ctx.user.id, DateTime.add(now, 20, :day))

      assert OfferedTimes.list_with_status(type, now) == [{soon, :bookable}, {far, :bookable}]
      assert OfferedTimes.next_by_type([type], now) == %{type.id => soon.starts_at}
    end

    test "leaves a type whose times are all out of reach off the public listing",
         %{type: type} = ctx do
      ids = fn -> ctx.user.id |> MeetingTypes.get_public_meeting_types() |> Enum.map(& &1.id) end
      {:ok, _too_far} = OfferedTimes.add(type, ctx.user.id, in_days(12))

      refute type.id in ids.()

      {:ok, _open} = OfferedTimes.add(type, ctx.user.id, in_days(3))

      assert type.id in ids.()
    end
  end

  describe "next_by_type/2 and prune_past/1" do
    test "skip a time the host's live booking takes, buffers included", ctx do
      type =
        insert(:meeting_type,
          user: ctx.user,
          max_participants: 1,
          fixed_dates: true,
          duration_minutes: 30,
          buffer_after_minutes: 15
        )

      {:ok, booked} = OfferedTimes.add(type, ctx.user.id, in_days(2))
      {:ok, next} = OfferedTimes.add(type, ctx.user.id, in_days(3))

      # Starts in the type's 15-minute buffer after the booked time's 30 minutes.
      meeting =
        insert(:meeting,
          organizer_user_id: ctx.user.id,
          start_time: DateTime.add(booked.starts_at, 40, :minute),
          end_time: DateTime.add(booked.starts_at, 70, :minute)
        )

      assert OfferedTimes.next_by_type([type]) == %{type.id => next.starts_at}

      insert(:meeting,
        organizer_user_id: ctx.user.id,
        start_time: next.starts_at,
        end_time: DateTime.add(next.starts_at, 30, :minute)
      )

      assert OfferedTimes.next_by_type([type]) == %{type.id => nil}

      meeting |> Changeset.change(status: :cancelled) |> Repo.update!()

      assert OfferedTimes.next_by_type([type]) == %{type.id => booked.starts_at}
    end

    test "ignore another host's bookings", ctx do
      {:ok, offered} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, in_days(2))
      stranger = insert(:user)

      insert(:meeting,
        organizer_user_id: stranger.id,
        start_time: offered.starts_at,
        end_time: DateTime.add(offered.starts_at, 30, :minute)
      )

      assert OfferedTimes.next_by_type([ctx.meeting_type]) == %{
               ctx.meeting_type.id => offered.starts_at
             }
    end

    test "name each type's next time and drop the ones that have started", ctx do
      other = insert(:meeting_type, user: ctx.user, max_participants: 1, fixed_dates: true)
      {:ok, soon} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, in_days(2))
      {:ok, _later} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, in_days(5))

      assert OfferedTimes.next_by_type([ctx.meeting_type, other]) == %{
               ctx.meeting_type.id => soon.starts_at,
               other.id => nil
             }

      assert {1, nil} = OfferedTimes.prune_past(in_days(3))
      assert [%{starts_at: starts_at}] = OfferedTimes.list(ctx.meeting_type)
      assert DateTime.compare(starts_at, soon.starts_at) == :gt
    end
  end
end
