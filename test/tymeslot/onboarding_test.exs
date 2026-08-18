defmodule Tymeslot.OnboardingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :utils

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Onboarding

  describe "get_or_create_profile/1" do
    test "creates a profile when none exists" do
      user = insert(:user)
      assert {:ok, profile} = Onboarding.get_or_create_profile(user.id)
      assert profile.user_id == user.id
    end

    test "the new profile comes with a default schedule and its seven weekdays" do
      user = insert(:user)
      {:ok, profile} = Onboarding.get_or_create_profile(user.id)

      assert %{is_default: true} = schedule = Schedules.get_default(profile.id)
      assert length(WeeklySchedule.get_weekly_schedule(schedule.id)) == 7
    end

    test "returns existing profile when one already exists" do
      user = insert(:user)
      {:ok, original_profile} = Onboarding.get_or_create_profile(user.id)
      {:ok, same_profile} = Onboarding.get_or_create_profile(user.id)
      assert same_profile.id == original_profile.id
    end
  end

  describe "get_or_create_profile/2" do
    test "returns dev profile in dev mode" do
      assert {:ok, profile} = Onboarding.get_or_create_profile(1, true)
      assert profile.id == 1
    end

    test "calls Profiles in non-dev mode" do
      user = insert(:user)
      assert {:ok, profile} = Onboarding.get_or_create_profile(user.id, false)
      assert profile.user_id == user.id
    end
  end

  describe "complete_onboarding/1" do
    test "marks user onboarding as complete" do
      user = insert(:user, onboarding_completed_at: nil)
      assert {:ok, updated_user} = Onboarding.complete_onboarding(user)
      assert %DateTime{} = updated_user.onboarding_completed_at
    end

    test "is idempotent for already-completed users" do
      user = insert(:user, onboarding_completed_at: nil)
      {:ok, completed_user} = Onboarding.complete_onboarding(user)
      {:ok, re_completed_user} = Onboarding.complete_onboarding(completed_user)

      assert re_completed_user.onboarding_completed_at ==
               completed_user.onboarding_completed_at
    end
  end

  describe "complete_onboarding/2" do
    test "returns user in dev mode" do
      user = %{id: 1}
      assert {:ok, ^user} = Onboarding.complete_onboarding(user, true)
    end

    test "calls Auth in non-dev mode" do
      user = insert(:user, onboarding_completed_at: nil)
      assert {:ok, updated_user} = Onboarding.complete_onboarding(user, false)
      assert %DateTime{} = updated_user.onboarding_completed_at
    end

    test "emits [:tymeslot, :onboarding, :completed] telemetry for a real user" do
      user = insert(:user, onboarding_completed_at: nil)
      test_pid = self()

      :telemetry.attach(
        "test-onboarding-completed",
        [:tymeslot, :onboarding, :completed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-onboarding-completed") end)

      assert {:ok, _updated} = Onboarding.complete_onboarding(user, false)
      assert_received {:telemetry, %{count: 1}, %{}}
    end

    test "does NOT emit telemetry in dev_mode" do
      user = %{id: 1}
      test_pid = self()

      :telemetry.attach(
        "test-onboarding-completed-devmode",
        [:tymeslot, :onboarding, :completed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-onboarding-completed-devmode") end)

      assert {:ok, _user} = Onboarding.complete_onboarding(user, true)
      refute_received {:telemetry, _, _}
    end
  end

  describe "dashboard tour helpers" do
    test "dashboard_tour_seen?/1 returns false for a user with no timestamp" do
      user = insert(:user, dashboard_tour_seen_at: nil)
      refute Onboarding.dashboard_tour_seen?(user)
    end

    test "dashboard_tour_seen?/1 returns true for a user with a timestamp" do
      user = insert(:user, dashboard_tour_seen_at: DateTime.utc_now(:second))
      assert Onboarding.dashboard_tour_seen?(user)
    end

    test "mark_dashboard_tour_seen/1 sets the timestamp when nil" do
      user = insert(:user, dashboard_tour_seen_at: nil)

      assert {:ok, updated} = Onboarding.mark_dashboard_tour_seen(user)
      assert %DateTime{} = updated.dashboard_tour_seen_at
    end

    test "mark_dashboard_tour_seen/1 is idempotent — second call does not overwrite the first timestamp" do
      user = insert(:user, dashboard_tour_seen_at: nil)

      {:ok, first} = Onboarding.mark_dashboard_tour_seen(user)
      {:ok, second} = Onboarding.mark_dashboard_tour_seen(first)

      assert second.dashboard_tour_seen_at == first.dashboard_tour_seen_at
    end
  end

  describe "dashboard setup widget helpers" do
    test "toggle_dashboard_setup_item/2 ticks an item and reflects in the predicate" do
      user = insert(:user)
      refute Onboarding.dashboard_setup_item_done?(user, "theme")

      {:ok, updated} = Onboarding.toggle_dashboard_setup_item(user, "theme")

      assert Onboarding.dashboard_setup_item_done?(updated, "theme")
      assert "theme" in updated.dashboard_setup_done_items
    end

    test "toggle_dashboard_setup_item/2 un-ticks an already-done item" do
      user = insert(:user, dashboard_setup_done_items: ["theme"])

      {:ok, updated} = Onboarding.toggle_dashboard_setup_item(user, "theme")

      refute Onboarding.dashboard_setup_item_done?(updated, "theme")
      assert updated.dashboard_setup_done_items == []
    end

    test "dismiss_dashboard_setup/1 stamps the timestamp and is idempotent" do
      user = insert(:user, dashboard_setup_dismissed_at: nil)
      refute Onboarding.dashboard_setup_dismissed?(user)

      {:ok, first} = Onboarding.dismiss_dashboard_setup(user)
      assert Onboarding.dashboard_setup_dismissed?(first)

      {:ok, second} = Onboarding.dismiss_dashboard_setup(first)
      assert second.dashboard_setup_dismissed_at == first.dashboard_setup_dismissed_at
    end
  end
end
