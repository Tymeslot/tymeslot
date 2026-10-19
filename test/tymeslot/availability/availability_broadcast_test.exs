defmodule Tymeslot.Availability.AvailabilityBroadcastTest do
  @moduledoc """
  `Availability.changed/1` tells subscribers, not only the slot cache: the
  organiser's calendar subscribes with `Availability.subscribe/1` and reloads
  its bookable times on `{:availability_changed, user_id}`. Checked for each
  shape `changed/1` takes and for the writes the calendar itself makes or
  answers: accepting or declining a request, a guest withdrawing one, a
  cancellation, and opening a slot for booking.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Availability
  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.Opening
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    :ok
  end

  defp held_meeting(user) do
    insert(:meeting,
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
    )
  end

  describe "changed/1" do
    test "broadcasts to the user's subscribers, by user id" do
      user = insert(:user)
      :ok = Availability.subscribe(user.id)

      assert :ok = Availability.changed(user.id)
      assert_receive {:availability_changed, user_id}
      assert user_id == user.id
    end

    test "broadcasts for a profile and for a schedule, to the user owning them" do
      %{user: user, profile: profile, schedule: schedule} = create_bookable_profile()
      :ok = Availability.subscribe(user.id)

      Availability.changed(profile)
      assert_receive {:availability_changed, user_id} when user_id == user.id

      Availability.changed(schedule)
      assert_receive {:availability_changed, user_id} when user_id == user.id
    end

    test "does not reach another user's subscribers" do
      user = insert(:user)
      other = insert(:user)
      :ok = Availability.subscribe(user.id)

      Availability.changed(other.id)
      refute_receive {:availability_changed, _user_id}, 100
    end

    test "nil changes nothing and tells no one" do
      user = insert(:user)
      :ok = Availability.subscribe(user.id)

      assert :ok = Availability.changed(nil)
      refute_receive {:availability_changed, _user_id}, 100
    end
  end

  describe "the writes the calendar acts on" do
    test "accepting a request" do
      user = insert(:user)
      meeting = held_meeting(user)
      :ok = Availability.subscribe(user.id)

      assert {:ok, _confirmed} = Approval.approve(meeting)
      assert_receive {:availability_changed, user_id} when user_id == user.id
    end

    test "declining a request" do
      user = insert(:user)
      meeting = held_meeting(user)
      :ok = Availability.subscribe(user.id)

      assert {:ok, _declined} = Approval.decline(meeting, nil)
      assert_receive {:availability_changed, user_id} when user_id == user.id
    end

    test "a guest withdrawing a request" do
      user = insert(:user)
      meeting = held_meeting(user)
      :ok = Availability.subscribe(user.id)

      assert {:ok, _withdrawn} = Cancel.execute(meeting)
      assert_receive {:availability_changed, user_id} when user_id == user.id
    end

    test "cancelling a confirmed booking" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})
      {:ok, loaded} = MeetingQueries.get_meeting_by_uid(meeting.uid)
      :ok = Availability.subscribe(user.id)

      assert {:ok, _cancelled} = Cancel.execute(loaded)
      assert_receive {:availability_changed, user_id} when user_id == user.id
    end

    test "opening a slot for booking" do
      %{user: user} = create_bookable_profile()
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)
      date = next_bookable_weekday()
      :ok = Availability.subscribe(user.id)

      assert {:ok, _opened} =
               Opening.open_once(
                 user.id,
                 meeting_type.id,
                 DateTime.new!(date, ~T[18:00:00], "Etc/UTC"),
                 DateTime.new!(date, ~T[19:00:00], "Etc/UTC")
               )

      assert_receive {:availability_changed, user_id} when user_id == user.id
    end

    test "opening every week on a date with hours of its own tells once, after both writes" do
      %{user: user, schedule: schedule} = create_bookable_profile()
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)
      date = next_bookable_weekday()

      insert(:availability_override,
        schedule: schedule,
        date: date,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[12:00:00]
      )

      :ok = Availability.subscribe(user.id)

      assert {:ok, %{previous: %{override: %{date: ^date}}}} =
               Opening.open_weekly(
                 user.id,
                 meeting_type.id,
                 DateTime.new!(date, ~T[18:00:00], "Etc/UTC"),
                 DateTime.new!(date, ~T[19:00:00], "Etc/UTC")
               )

      assert_received {:availability_changed, user_id} when user_id == user.id
      refute_received {:availability_changed, _user_id}
    end
  end

  describe "a refused write tells nobody" do
    test "a weekly restore that fails part way, and so writes nothing" do
      %{user: user, schedule: schedule} = create_bookable_profile()
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)
      date = next_bookable_weekday()

      insert(:availability_override,
        schedule: schedule,
        date: date,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[12:00:00]
      )

      {:ok, result} =
        Opening.open_weekly(
          user.id,
          meeting_type.id,
          DateTime.new!(date, ~T[18:00:00], "Etc/UTC"),
          DateTime.new!(date, ~T[19:00:00], "Etc/UTC")
        )

      broken = put_in(result, [:previous, :override, :was, :override_type], "unknown")
      :ok = Availability.subscribe(user.id)

      assert {:error, :invalid_hours} = Opening.restore(user.id, broken)
      refute_received {:availability_changed, _user_id}
    end

    test "weekly hours the editor refuses" do
      %{user: user, profile: profile, schedule: schedule} = create_bookable_profile()
      :ok = Availability.subscribe(user.id)

      assert {:error, :invalid_time_format} =
               AvailabilityActions.update_day_hours(profile.id, schedule.id, 1, "nine", "17:00")

      refute_received {:availability_changed, _user_id}

      assert {:ok, _day} =
               AvailabilityActions.update_day_hours(profile.id, schedule.id, 1, "09:00", "17:00")

      assert_received {:availability_changed, user_id} when user_id == user.id
    end
  end
end
