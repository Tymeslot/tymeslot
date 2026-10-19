defmodule Tymeslot.Profiles.ChangeUsernameTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Security.RateLimiter

  describe "publishing the booking page on username set" do
    test "publishes when the user already has an active meeting type" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)
      insert(:meeting_type, user: user, is_active: true)

      assert {:ok, _updated} = Profiles.change_username(profile, "newhost")

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert %DateTime{} = reloaded.booking_page_published_at
    end

    test "does not publish when the user has no active meeting type" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)

      assert {:ok, _updated} = Profiles.change_username(profile, "newhost")

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert reloaded.booking_page_published_at == nil
    end

    test "a system-assigned username publishes when the user already has an active meeting type" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)
      insert(:meeting_type, user: user, is_active: true)

      assert {:ok, _updated} = Profiles.ensure_default_username(profile)

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert %DateTime{} = reloaded.booking_page_published_at
    end
  end

  describe "change_username/2" do
    test "refuses a change once the user's change allowance is spent" do
      profile = insert(:profile, username: nil)
      exhaust_username_changes(profile)

      assert {:error, "Too many username change attempts. Please try again later."} =
               Profiles.change_username(profile, "limited-host")
    end

    test "writes nothing for the profile's current username" do
      profile = insert(:profile, username: "same-host")

      assert {:ok, ^profile} = Profiles.change_username(profile, "same-host")
    end
  end

  describe "ensure_default_username/1" do
    test "gives a blank username the default even with the change allowance spent" do
      profile = insert(:profile, username: nil)
      exhaust_username_changes(profile)
      expected = "user_#{profile.user_id}"

      assert {:ok, %{username: ^expected}} = Profiles.ensure_default_username(profile)
      assert {:ok, %{username: ^expected}} = ProfileQueries.get_by_user_id(profile.user_id)
    end

    test "gives an empty-string username the default" do
      profile = insert(:profile, username: nil)
      profile = %{profile | username: ""}
      expected = "user_#{profile.user_id}"

      assert {:ok, %{username: ^expected}} = Profiles.ensure_default_username(profile)
    end

    test "keeps a username chosen since the profile was read" do
      stale = insert(:profile, username: nil)
      {:ok, _chosen} = ProfileQueries.update_username(stale, "chosen-meanwhile")

      assert {:ok, %{username: "chosen-meanwhile"}} = Profiles.ensure_default_username(stale)

      assert {:ok, %{username: "chosen-meanwhile"}} =
               ProfileQueries.get_by_user_id(stale.user_id)
    end

    test "leaves an existing username alone" do
      profile = insert(:profile, username: "chosen-host")

      assert {:ok, ^profile} = Profiles.ensure_default_username(profile)
      assert {:ok, %{username: "chosen-host"}} = ProfileQueries.get_by_user_id(profile.user_id)
    end

    # Onboarding reads the profile, then gives it the default; the profile
    # can be deleted in between.
    test "answers not found for a profile deleted since it was read" do
      profile = insert(:profile, username: nil)
      Repo.delete!(profile)

      assert {:error, :not_found} = Profiles.ensure_default_username(profile)
    end
  end

  defp exhaust_username_changes(profile) do
    key = "user:" <> Integer.to_string(profile.user_id)
    for _n <- 1..6, do: RateLimiter.check(:username_change, key)
  end
end
