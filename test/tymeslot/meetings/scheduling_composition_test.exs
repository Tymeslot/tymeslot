defmodule Tymeslot.Meetings.SchedulingCompositionTest do
  @moduledoc """
  Composition tests for `Tymeslot.Meetings.Scheduling`. The module wraps
  meeting create/update in a conflict-checked transaction with buffered
  windows derived from the organiser's profile. These tests exercise the
  buffer arithmetic and the short-circuit path that skips the conflict
  check when the update does not touch time.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Meetings.Scheduling

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user)
    insert(:availability_schedule, profile: profile, is_default: true, buffer_minutes: 15)
    %{user: user, profile: profile}
  end

  describe "create_meeting_with_conflict_check/1" do
    test "creates meeting when no conflicts exist", %{user: user} do
      start_time = future_time(2, :day)

      assert {:ok, meeting} =
               Scheduling.create_meeting_with_conflict_check(attrs(user, start_time))

      assert DateTime.compare(meeting.start_time, start_time) == :eq
    end

    test "rejects meeting that overlaps with existing meeting", %{user: user} do
      base = future_time(2, :day)
      insert_meeting(user, base)

      overlap_start = DateTime.add(base, 15, :minute)

      assert {:error, :time_conflict} =
               Scheduling.create_meeting_with_conflict_check(attrs(user, overlap_start))
    end

    test "rejects meeting within 15-minute buffer of existing meeting", %{user: user} do
      base = future_time(2, :day)
      insert_meeting(user, base)

      # existing ends at base+30m; new starts at base+35m -> 5m gap, < 15m buffer
      buffer_start = DateTime.add(base, 35, :minute)

      assert {:error, :time_conflict} =
               Scheduling.create_meeting_with_conflict_check(attrs(user, buffer_start))
    end

    test "allows meeting outside the buffer window", %{user: user} do
      base = future_time(2, :day)
      insert_meeting(user, base)

      # existing ends at base+30m; buffer is 15m -> clear after base+45m
      outside_start = DateTime.add(base, 60, :minute)

      assert {:ok, _meeting} =
               Scheduling.create_meeting_with_conflict_check(attrs(user, outside_start))
    end

    test "pins the strict buffer boundary (exact edge at base+45m)", %{user: user} do
      base = future_time(2, :day)
      insert_meeting(user, base)

      # existing ends at base+30m; with a 15m buffer the buffered_end is base+45m.
      # A new meeting starting at base+45m has buffered_start = base+30m.
      # The conflict query uses end_time > ^buffered_start (strict), so
      # base+45m == base+45m is false -> no conflict.
      exact_edge = DateTime.add(base, 45, :minute)

      assert {:ok, _meeting} =
               Scheduling.create_meeting_with_conflict_check(attrs(user, exact_edge))

      # One minute inside the buffer (base+44m): buffered_start = base+29m,
      # existing end_time = base+45m -> base+45m > base+29m is true -> conflict.
      one_inside = DateTime.add(base, 44, :minute)

      assert {:error, :time_conflict} =
               Scheduling.create_meeting_with_conflict_check(attrs(user, one_inside))
    end

    test "returns {:error, {:validation_error, changeset}} when attrs fail schema validation",
         %{user: user} do
      start_time = future_time(2, :day)
      # omit organizer_email, which is required by the changeset
      invalid_attrs = user |> attrs(start_time) |> Map.delete(:organizer_email)

      assert {:error, {:validation_error, %Ecto.Changeset{valid?: false}}} =
               Scheduling.create_meeting_with_conflict_check(invalid_attrs)
    end

    test "returns :invalid_time_range when start_time missing", %{user: user} do
      attrs = user |> attrs(future_time(1, :day)) |> Map.delete(:start_time)

      assert {:error, :invalid_time_range} =
               Scheduling.create_meeting_with_conflict_check(attrs)
    end

    test "does not see other users' meetings as conflicts", %{user: user} do
      other_user = insert(:user)
      other_profile = insert(:profile, user: other_user)
      insert(:availability_schedule, profile: other_profile, is_default: true, buffer_minutes: 15)

      base = future_time(2, :day)
      insert_meeting(other_user, base)

      # Same time slot for `user` — the other user's meeting must not block it.
      assert {:ok, _meeting} =
               Scheduling.create_meeting_with_conflict_check(attrs(user, base))
    end
  end

  describe "update_meeting_with_conflict_check/2" do
    test "moves a meeting to a clear slot", %{user: user} do
      meeting = insert_meeting(user, future_time(2, :day))
      new_start = future_time(5, :day)

      assert {:ok, updated} =
               Scheduling.update_meeting_with_conflict_check(meeting, %{
                 start_time: new_start,
                 end_time: DateTime.add(new_start, 30, :minute)
               })

      assert DateTime.compare(updated.start_time, new_start) == :eq
    end

    test "rejects a move that collides with another meeting", %{user: user} do
      other = insert_meeting(user, future_time(5, :day))
      meeting = insert_meeting(user, future_time(2, :day))

      assert {:error, :time_conflict} =
               Scheduling.update_meeting_with_conflict_check(meeting, %{
                 start_time: other.start_time,
                 end_time: other.end_time
               })
    end

    test "skips conflict check when attrs contain no time fields", %{user: user} do
      # `meeting` and `_blocker` are in overlapping slots for the same organiser.
      # Because the blocker has a different uid it is not excluded from the
      # conflict query. If the skip path were removed, updating only the title
      # would run the conflict check, find the blocker, and rollback. The skip
      # path must short-circuit for this update to succeed.
      base = future_time(2, :day)
      meeting = insert_meeting(user, base)
      # Start the blocker 10 minutes later so it overlaps but avoids the unique
      # constraint on (organizer_user_id, start_time).
      _blocker = insert_meeting(user, DateTime.add(base, 10, :minute))

      assert {:ok, updated} =
               Scheduling.update_meeting_with_conflict_check(meeting, %{title: "Renamed"})

      assert updated.title == "Renamed"
    end
  end

  describe "has_time_conflict?/3" do
    test "returns true when overlap exists", %{user: user} do
      base = future_time(2, :day)
      insert_meeting(user, base)

      assert Scheduling.has_time_conflict?(base, DateTime.add(base, 30, :minute))
    end

    test "returns true for overlaps across any organiser (global scope)" do
      other_user = insert(:user)
      other_profile = insert(:profile, user: other_user)
      insert(:availability_schedule, profile: other_profile, is_default: true, buffer_minutes: 15)

      base = future_time(3, :day)
      insert_meeting(other_user, base)

      # No meeting for setup `user` exists at this slot; the only overlap
      # belongs to other_user. The query is global, so it must still return true.
      assert Scheduling.has_time_conflict?(base, DateTime.add(base, 30, :minute))
    end

    test "returns false when the given uid matches the only overlapping meeting", %{user: user} do
      base = future_time(2, :day)
      meeting = insert_meeting(user, base)

      refute Scheduling.has_time_conflict?(
               base,
               DateTime.add(base, 30, :minute),
               meeting.uid
             )
    end
  end

  # ----- helpers -----

  defp future_time(amount, unit) do
    DateTime.utc_now() |> DateTime.add(amount, unit) |> DateTime.truncate(:second)
  end

  defp attrs(user, start_time) do
    %{
      uid: UUID.generate(),
      title: "Composition Test Meeting",
      summary: "Composition Test Meeting",
      description: "",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      organizer_user_id: user.id,
      organizer_name: "Organiser",
      organizer_email: "organiser-#{user.id}@example.com",
      attendee_name: "Attendee",
      attendee_email: "attendee-#{System.unique_integer([:positive])}@example.com",
      attendee_timezone: "Etc/UTC",
      attendee_locale: "en",
      status: "confirmed"
    }
  end

  defp insert_meeting(user, start_time) do
    insert(:meeting,
      uid: UUID.generate(),
      organizer_user_id: user.id,
      organizer_email: "organiser-#{user.id}@example.com",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      status: "confirmed"
    )
  end
end
