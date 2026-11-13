defmodule Tymeslot.Profiles.CreateProfileTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

  describe "create_profile/1" do
    # The loser of two concurrent first loads used to raise
    # Ecto.ConstraintError; it now gets the profile the winner created.
    test "returns the existing profile when one was created first" do
      user = insert(:user)
      {:ok, first} = Profiles.create_profile(user.id)

      assert {:ok, second} = Profiles.create_profile(user.id)
      assert second.id == first.id
    end

    test "refuses a user deleted meanwhile without raising" do
      user = insert(:user)
      Repo.delete!(user)

      assert {:error, :user_not_found} = Profiles.create_profile(user.id)
    end

    # The defaults are seeded here, once; nothing seeds them again.
    test "a new profile gets one Intro call meeting type" do
      user = insert(:user)
      {:ok, _profile} = Profiles.create_profile(user.id)

      assert [type] = MeetingTypes.get_all_meeting_types(user.id)
      assert type.name == "Intro call"
      assert type.duration_minutes == 30
      assert type.is_active
      assert [%{kind: :in_person}] = type.locations
    end
  end

  describe "get_or_create_profile/1" do
    test "refuses a user deleted meanwhile without raising" do
      user = insert(:user)
      Repo.delete!(user)

      assert {:error, :user_not_found} = Profiles.get_or_create_profile(user.id)
    end
  end
end
