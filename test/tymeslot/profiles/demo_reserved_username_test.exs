defmodule Tymeslot.Profiles.DemoReservedUsernameTest do
  @moduledoc """
  A username the demo provider reserves can never be newly chosen, while a
  profile that held it before it was reserved keeps it.
  """

  # Swaps the node-wide demo provider, so it must not run beside other tests.
  use Tymeslot.DataCase, async: false

  @moduletag :profiles
  @moduletag :schema

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Demo.NoOp
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Test.ReservingDemoProvider

  @demo_username ReservingDemoProvider.reserved_username()

  defp username_changeset(profile, username) do
    ProfileSchema.username_changeset(profile, %{username: username})
  end

  describe "with a demo provider that reserves the username" do
    setup do
      with_config(:tymeslot, demo_provider: ReservingDemoProvider)
      :ok
    end

    test "a new profile cannot take it" do
      user = insert(:user)
      changeset = username_changeset(%ProfileSchema{user_id: user.id}, @demo_username)

      refute changeset.valid?
      assert "is reserved" in errors_on(changeset)[:username]
      assert Profiles.username_error(changeset) == :reserved
    end

    test "an existing profile cannot change to it" do
      profile = insert(:profile, username: "sarah")
      changeset = username_changeset(profile, @demo_username)

      refute changeset.valid?
      assert "is reserved" in errors_on(changeset)[:username]
      assert Profiles.username_status(profile, @demo_username) == :reserved
    end

    test "a refused attempt to change to it spends no change attempt" do
      profile = insert(:profile, username: "sarah")

      # More refusals than the change allowance holds: had any of them
      # counted, the valid change below would be rate limited.
      for _attempt <- 1..6 do
        assert {:error, "This username is reserved"} =
                 Profiles.change_username(profile, @demo_username)
      end

      assert {:ok, %{username: "sarah-new"}} = Profiles.change_username(profile, "sarah-new")
    end

    test "a capitalised variant is refused by the username format" do
      profile = insert(:profile, username: "sarah")
      capitalised = String.capitalize(@demo_username)

      assert {:error, "Username must start with a letter or number" <> _rest} =
               Profiles.change_username(profile, capitalised)

      assert {:invalid, _message} = Profiles.username_status(profile, capitalised)
      assert Repo.reload!(profile).username == "sarah"
    end

    test "a username it does not reserve stays free" do
      profile = insert(:profile, username: "sarah")

      assert username_changeset(profile, "demo-x-2").valid?
      assert Profiles.username_status(profile, "demo-x-2") == :ok
    end

    test "an existing profile that already holds it is not re-validated" do
      # Inserted past the changeset, as a handle chosen before it was reserved.
      profile = insert(:profile, username: @demo_username)

      assert username_changeset(profile, @demo_username).valid?
      assert ProfileSchema.basic_changeset(profile, %{full_name: "Sarah Rodriguez"}).valid?
      assert Profiles.username_status(profile, @demo_username) == :unchanged
    end
  end

  describe "with the no-op demo provider" do
    test "the same username can be chosen" do
      with_config(:tymeslot, demo_provider: NoOp)
      profile = insert(:profile, username: "sarah")

      assert username_changeset(profile, @demo_username).valid?
      assert Profiles.username_status(profile, @demo_username) == :ok
    end
  end
end
