defmodule Tymeslot.Profiles.DemoReservedUsernameTest do
  @moduledoc """
  A username the demo provider serves can never be chosen: the provider would
  answer for it, replacing the organiser's booking page with demo content.
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
    ProfileSchema.changeset(profile, %{username: username, timezone: "Europe/London"})
  end

  describe "with a demo provider that serves the username" do
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

    test "a username it does not serve stays free" do
      profile = insert(:profile, username: "sarah")

      assert username_changeset(profile, "demo-x-2").valid?
      assert Profiles.username_status(profile, "demo-x-2") == :ok
    end

    test "an existing profile that already holds it is not re-validated" do
      # Inserted past the changeset, as a handle chosen before it was reserved.
      profile = insert(:profile, username: @demo_username)

      assert username_changeset(profile, @demo_username).valid?
      assert ProfileSchema.changeset(profile, %{full_name: "Sarah Rodriguez"}).valid?
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
