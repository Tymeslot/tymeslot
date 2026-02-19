defmodule TymeslotWeb.Hooks.AuthLiveSessionHookTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: true

  @moduletag :hooks

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Hooks.AuthLiveSessionHook

  defp build_socket(assigns \\ %{}) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      endpoint: TymeslotWeb.Endpoint
    }
  end

  describe "on_mount(:ensure_authenticated, ...)" do
    test "redirects when no token in session" do
      socket = build_socket()

      assert {:halt, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_authenticated, %{}, %{}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/auth/login", status: 302}}
    end

    test "redirects when token exists but session expired" do
      socket = build_socket()
      session = %{"user_token" => "expired-nonexistent-token"}

      assert {:halt, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_authenticated, %{}, session, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/auth/login", status: 302}}
    end

    test "assigns current_user and is_email_verified on valid token" do
      user = insert(:user, verified_at: DateTime.utc_now())
      session_record = insert(:user_session, user: user)
      socket = build_socket()
      session = %{"user_token" => session_record.token}

      assert {:cont, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_authenticated, %{}, session, socket)

      assert updated_socket.assigns.current_user.id == user.id
      assert updated_socket.assigns.is_email_verified == true
    end

    test "assigns is_email_verified as false for unverified user" do
      user = insert(:unverified_user)
      session_record = insert(:user_session, user: user)
      socket = build_socket()
      session = %{"user_token" => session_record.token}

      assert {:cont, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_authenticated, %{}, session, socket)

      assert updated_socket.assigns.current_user.id == user.id
      assert updated_socket.assigns.is_email_verified == false
    end
  end

  describe "on_mount(:fetch_current_user, ...)" do
    test "assigns nil when no token" do
      socket = build_socket()

      assert {:cont, updated_socket} =
               AuthLiveSessionHook.on_mount(:fetch_current_user, %{}, %{}, socket)

      assert updated_socket.assigns.current_user == nil
    end

    test "assigns user when valid token" do
      user = insert(:user)
      session_record = insert(:user_session, user: user)
      socket = build_socket()
      session = %{"user_token" => session_record.token}

      assert {:cont, updated_socket} =
               AuthLiveSessionHook.on_mount(:fetch_current_user, %{}, session, socket)

      assert updated_socket.assigns.current_user.id == user.id
    end

    test "assigns nil when token exists but invalid" do
      socket = build_socket()
      session = %{"user_token" => "invalid-token"}

      assert {:cont, updated_socket} =
               AuthLiveSessionHook.on_mount(:fetch_current_user, %{}, session, socket)

      assert updated_socket.assigns.current_user == nil
    end
  end

  describe "on_mount(:ensure_not_authenticated, ...)" do
    test "allows access when no token" do
      socket = build_socket()

      assert {:cont, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_not_authenticated, %{}, %{}, socket)

      assert updated_socket.assigns.current_user == nil
    end

    test "redirects authenticated users to dashboard" do
      user = insert(:user)
      session_record = insert(:user_session, user: user)
      socket = build_socket()
      session = %{"user_token" => session_record.token}

      assert {:halt, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_not_authenticated, %{}, session, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/dashboard", status: 302}}
    end

    test "allows access when token exists but invalid" do
      socket = build_socket()
      session = %{"user_token" => "invalid-token"}

      assert {:cont, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_not_authenticated, %{}, session, socket)

      assert updated_socket.assigns.current_user == nil
    end
  end
end
