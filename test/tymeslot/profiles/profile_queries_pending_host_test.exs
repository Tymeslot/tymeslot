defmodule Tymeslot.Profiles.ProfileQueriesPendingHostTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Profiles.ProfileQueries

  defp pending_user do
    now = DateTime.utc_now(:second)
    insert(:user, deletion_requested_at: now, deletion_scheduled_at: DateTime.add(now, 14, :day))
  end

  test "a host pending deletion is not found by username" do
    profile = insert(:profile, user: pending_user(), username: "gone-soon")

    assert ProfileQueries.get_by_username(profile.username) == {:error, :not_found}
    assert ProfileQueries.get_by_username_with_user(profile.username) == {:error, :not_found}
  end

  test "an active host still is" do
    profile = insert(:profile, user: insert(:user), username: "still-here")

    assert {:ok, %{id: id}} = ProfileQueries.get_by_username(profile.username)
    assert id == profile.id

    assert {:ok, %{user: %{id: _user_id}}} =
             ProfileQueries.get_by_username_with_user("still-here")
  end

  test "a host pending deletion has no free/busy feed" do
    profile = insert(:profile, user: pending_user(), username: "feedless")
    {:ok, _profile} = ProfileQueries.update_freebusy_token(profile, "feed-token-123")

    assert ProfileQueries.get_by_freebusy_token("feed-token-123") == {:error, :not_found}
  end

  test "an active host's free/busy feed still resolves" do
    profile = insert(:profile, user: insert(:user), username: "feeding")
    {:ok, _profile} = ProfileQueries.update_freebusy_token(profile, "feed-token-456")

    assert {:ok, %{id: id}} = ProfileQueries.get_by_freebusy_token("feed-token-456")
    assert id == profile.id
  end
end
