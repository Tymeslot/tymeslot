defmodule TymeslotWeb.Hooks.DashboardInitHookTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias TymeslotWeb.Hooks.DashboardInitHook

  defp build_socket(assigns \\ %{}) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      endpoint: TymeslotWeb.Endpoint,
      transport_pid: self()
    }
  end

  describe "on_mount/4" do
    test "continues when user is not present (handled by auth hooks)" do
      socket = build_socket()
      assert {:cont, ^socket} = DashboardInitHook.on_mount(:default, %{}, %{}, socket)
    end

    test "redirects to onboarding if onboarding is not completed" do
      user = insert(:user, onboarding_completed_at: nil)
      socket = build_socket(%{current_user: user})

      assert {:halt, socket} = DashboardInitHook.on_mount(:default, %{}, %{}, socket)
      assert socket.redirected == {:redirect, %{to: "/onboarding", status: 302}}
    end

    test "assigns profile and integration status when onboarding is completed" do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      profile = insert(:profile, user: user)
      socket = build_socket(%{current_user: user})

      assert {:cont, updated_socket} = DashboardInitHook.on_mount(:default, %{}, %{}, socket)
      assert updated_socket.assigns.profile.id == profile.id
      assert Map.has_key?(updated_socket.assigns, :integration_status)
      assert updated_socket.assigns.saving == false
    end

    test "creates a missing profile rather than assigning an unsaved one" do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      # No profile inserted
      socket = build_socket(%{current_user: user})

      assert {:cont, updated_socket} = DashboardInitHook.on_mount(:default, %{}, %{}, socket)

      assert %ProfileSchema{id: id, user_id: user_id} = updated_socket.assigns.profile
      assert user_id == user.id
      assert Profiles.get_profile(user.id).id == id
    end

    test "sends the visitor back to sign-in when the account was deleted meanwhile" do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      Repo.delete!(user)

      for socket <- [
            build_socket(%{current_user: user}),
            %{build_socket(%{current_user: user}) | transport_pid: nil}
          ] do
        assert {:halt, halted} = DashboardInitHook.on_mount(:default, %{}, %{}, socket)
        assert halted.redirected == {:redirect, %{to: "/auth/login", status: 302}}
      end
    end
  end
end
