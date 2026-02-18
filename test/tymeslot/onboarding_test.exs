defmodule Tymeslot.OnboardingTest do
  @moduletag :utils
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Onboarding

  describe "get_steps/0" do
  @moduletag :utils
    test "returns the list of steps" do
      assert Onboarding.get_steps() == [
               :welcome,
               :basic_settings,
               :scheduling_preferences,
               :complete
             ]
    end
  end

  describe "next_step/1" do
    test "returns the next step in sequence" do
      assert Onboarding.next_step(:welcome) == {:ok, :basic_settings}
      assert Onboarding.next_step(:basic_settings) == {:ok, :scheduling_preferences}
      assert Onboarding.next_step(:scheduling_preferences) == {:ok, :complete}
      assert Onboarding.next_step(:complete) == {:complete, :complete}
    end

    test "returns error for invalid step" do
      assert Onboarding.next_step(:invalid) == {:error, :invalid_step}
    end
  end

  describe "previous_step/1" do
    test "returns the previous step in sequence" do
      assert Onboarding.previous_step(:basic_settings) == {:ok, :welcome}
      assert Onboarding.previous_step(:scheduling_preferences) == {:ok, :basic_settings}
      assert Onboarding.previous_step(:complete) == {:ok, :scheduling_preferences}
    end

    test "returns error for first step" do
      assert Onboarding.previous_step(:welcome) == {:error, :first_step}
    end

    test "returns error for invalid step" do
      assert Onboarding.previous_step(:invalid) == {:error, :invalid_step}
    end
  end

  describe "dev helpers" do
    test "create_dev_profile/0 returns a mock profile" do
      profile = Onboarding.create_dev_profile()
      assert profile.id == 1
      assert profile.timezone == "Europe/Kyiv"
    end

    test "create_dev_user/0 returns a mock user" do
      user = Onboarding.create_dev_user()
      assert user.id == 1
      assert user.email == "dev@example.com"
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
  end

  describe "valid_step?/1" do
    test "validates atoms" do
      assert Onboarding.valid_step?(:welcome)
      assert Onboarding.valid_step?(:complete)
      refute Onboarding.valid_step?(:invalid)
    end

    test "validates strings" do
      assert Onboarding.valid_step?("welcome")
      assert Onboarding.valid_step?("complete")
      refute Onboarding.valid_step?("invalid")
    end

    test "handles non-existing atoms in strings" do
      refute Onboarding.valid_step?("non_existent_atom_string")
    end

    test "handles other types" do
      refute Onboarding.valid_step?(123)
      refute Onboarding.valid_step?(nil)
    end
  end
end
