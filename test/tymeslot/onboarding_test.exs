defmodule Tymeslot.OnboardingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :utils

  alias Tymeslot.Onboarding

  describe "dev helpers" do
    test "create_dev_profile/0 returns a mock profile" do
      profile = Onboarding.create_dev_profile()
      assert profile.id == 1
      assert profile.timezone == "Europe/Tallinn"
    end

    test "create_dev_user/0 returns a mock user" do
      user = Onboarding.create_dev_user()
      assert user.id == 1
      assert user.email == "dev@example.com"
    end
  end

  describe "get_or_create_profile/1" do
    test "creates a profile when none exists" do
      user = insert(:user)
      assert {:ok, profile} = Onboarding.get_or_create_profile(user.id)
      assert profile.user_id == user.id
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
      assert updated_user.onboarding_completed_at != nil
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
      assert updated_user.onboarding_completed_at != nil
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
end
