defmodule Tymeslot.Profiles.UsernameStatusTest do
  @moduledoc """
  Whether a username can be used, and why not, as every username form asks it:
  onboarding, the profile settings page, and the write that settles a race.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :unit

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema

  describe "username_status/2" do
    setup do
      %{profile: insert(:profile, username: "sarah")}
    end

    test "is :unchanged for the profile's own username, surrounding spaces included",
         %{profile: profile} do
      assert Profiles.username_status(profile, "sarah") == :unchanged
      assert Profiles.username_status(profile, "  sarah ") == :unchanged
    end

    test "is :unchanged for a legacy username that has since become reserved" do
      # Inserted past the changeset, as a handle chosen before the word was reserved.
      legacy = insert(:profile, username: "admin")

      assert Profiles.username_status(legacy, "admin") == :unchanged
    end

    test "is :ok for a free, well-formed username", %{profile: profile} do
      assert Profiles.username_status(profile, "sarah-r") == :ok
      assert Profiles.username_status(nil, "  sarah-r ") == :ok
    end

    test "is :invalid with the reason for a malformed username", %{profile: profile} do
      assert {:invalid, "Username must be at least 3 characters long"} =
               Profiles.username_status(profile, "ab")

      assert {:invalid, message} = Profiles.username_status(profile, "Admin")
      assert message =~ "lowercase"
    end

    test "is :reserved for a reserved username", %{profile: profile} do
      assert Profiles.username_status(profile, "admin") == :reserved
      assert Profiles.username_status(profile, "jesus-christ") == :reserved
      assert Profiles.username_status(nil, " admin ") == :reserved
    end

    test "is :taken for another profile's username", %{profile: profile} do
      insert(:profile, username: "taken-name")

      assert Profiles.username_status(profile, "taken-name") == :taken
      assert Profiles.username_status(profile, " taken-name  ") == :taken
    end

    test "is :taken for another profile's username in a different case", %{profile: profile} do
      # Inserted past the changeset, the only way a non-lowercase handle can
      # exist. The unique index is on lower(username), so this handle is taken
      # in every case and the save would be refused; the check has to say so
      # while the user is still typing, not a round trip later.
      insert(:profile, username: "Taken-Name")

      assert Profiles.username_status(profile, "taken-name") == :taken
    end
  end

  describe "username_error/1" do
    test "is :taken when the database refused a duplicate username" do
      insert(:profile, username: "taken-name")
      profile = insert(:profile, username: "sarah")

      assert {:error, changeset} = ProfileQueries.update_username(profile, "taken-name")
      assert Profiles.username_error(changeset) == :taken
    end

    test "is :reserved when the username is reserved" do
      changeset = ProfileSchema.changeset(insert(:profile), %{username: "admin"})

      assert Profiles.username_error(changeset) == :reserved
    end

    test "is nil when nothing is wrong with the username's availability" do
      changeset = ProfileSchema.changeset(insert(:profile), %{username: "Sarah"})

      refute changeset.valid?
      assert Profiles.username_error(changeset) == nil
    end
  end
end
