defmodule Tymeslot.Demo.NoOpTest do
  use Tymeslot.DataCase, async: true

  @moduletag :demo

  alias Tymeslot.Demo.NoOp

  describe "NoOp provider" do
    test "demo_mode?/1 always returns false" do
      refute NoOp.demo_mode?(%{})
    end

    test "demo_username?/1 always returns false" do
      refute NoOp.demo_username?("any")
      refute NoOp.demo_username?("demo-theme-1")
    end

    test "demo_profile?/1 always returns false" do
      refute NoOp.demo_profile?(%{id: 1})
      refute NoOp.demo_profile?(nil)
    end

    test "booking_window_days/1 falls back to the standard 90-day window" do
      assert NoOp.booking_window_days(%{id: 1}) == 90
      assert NoOp.booking_window_days(nil) == 90
    end

    test "get_profile_by_user_id/1 returns profile by user id" do
      user = insert(:user)
      profile = insert(:profile, user: user)
      assert NoOp.get_profile_by_user_id(user.id).id == profile.id
    end

    test "get_orchestrator/1 always returns core Orchestrator" do
      assert NoOp.get_orchestrator(%{}) == Tymeslot.Bookings.Orchestrator
    end

    test "get_available_slots/6 always returns {:ok, []}" do
      assert {:ok, []} == NoOp.get_available_slots("2025-01-01", "30min", "UTC", 1, %{}, %{})
    end

    test "get_calendar_days/4 always returns []" do
      assert [] == NoOp.get_calendar_days("UTC", 2025, 1, %{})
    end
  end
end
