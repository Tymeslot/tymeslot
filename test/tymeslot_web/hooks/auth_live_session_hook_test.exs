defmodule TymeslotWeb.Hooks.AuthLiveSessionHookTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: true

  @moduletag :hooks
  @moduletag :auth

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Hooks.AuthLiveSessionHook

  # Mounted at `uri`, as `get_connect_info/2` reports it during a mount.
  defp build_socket(assigns \\ %{}, uri \\ "http://localhost/dashboard") do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      endpoint: TymeslotWeb.Endpoint,
      private: Map.put(%Socket{}.private, :connect_info, %{uri: URI.parse(uri)})
    }
  end

  describe "on_mount(:ensure_authenticated, ...)" do
    test "redirects when no token in session" do
      socket = build_socket()

      assert {:halt, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_authenticated, %{}, %{}, socket)

      assert updated_socket.redirected ==
               {:redirect, %{to: "/auth/login?redirect_to=%2Fdashboard", status: 302}}
    end

    test "names the page being mounted, query included, in the login link" do
      socket = build_socket(%{}, "http://localhost/dashboard/meetings?meeting=12")

      assert {:halt, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_authenticated, %{}, %{}, socket)

      assert updated_socket.redirected ==
               {:redirect,
                %{
                  to: "/auth/login?redirect_to=%2Fdashboard%2Fmeetings%3Fmeeting%3D12",
                  status: 302
                }}
    end

    # Once connected, `:uri` is the websocket's address, CSRF token and all,
    # not the page; naming it would send the user there after signing in.
    test "a connected mount sends the user to the plain login page" do
      socket = %{
        build_socket(
          %{},
          "http://localhost/live/websocket?_csrf_token=secret-token&vsn=2.0.0"
        )
        | transport_pid: self()
      }

      session = %{"user_token" => "expired-nonexistent-token"}

      assert {:halt, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_authenticated, %{}, session, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/auth/login", status: 302}}
    end

    test "redirects when token exists but session expired" do
      socket = build_socket()
      session = %{"user_token" => "expired-nonexistent-token"}

      assert {:halt, updated_socket} =
               AuthLiveSessionHook.on_mount(:ensure_authenticated, %{}, session, socket)

      assert updated_socket.redirected ==
               {:redirect, %{to: "/auth/login?redirect_to=%2Fdashboard", status: 302}}
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

  describe "on_mount({:redirect_if_authenticated, opts}, ...)" do
    @hook {:redirect_if_authenticated, actions: [:login, :signup], events: ["submit_signup"]}

    test "lets an anonymous visitor through" do
      socket = build_socket(%{live_action: :login})

      assert {:cont, updated_socket} = AuthLiveSessionHook.on_mount(@hook, %{}, %{}, socket)

      assert updated_socket.assigns.current_user == nil
    end

    test "redirects a signed-in user away from a listed action" do
      user = insert(:user)
      session_record = insert(:user_session, user: user)
      socket = build_socket(%{live_action: :login})
      session = %{"user_token" => session_record.token}

      assert {:halt, updated_socket} = AuthLiveSessionHook.on_mount(@hook, %{}, session, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/dashboard", status: 302}}
    end

    test "lets a signed-in user reach an action that is not listed" do
      user = insert(:user)
      session_record = insert(:user_session, user: user)
      # Mounted at the router, as the patch and event guards it attaches need.
      socket = %{
        build_socket(%{live_action: :reset_password_form})
        | router: TymeslotWeb.Router,
          private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}
      }

      session = %{"user_token" => session_record.token}

      assert {:cont, updated_socket} = AuthLiveSessionHook.on_mount(@hook, %{}, session, socket)

      assert updated_socket.assigns.current_user.id == user.id
    end

    test "lets a visitor with a dead token through" do
      socket = build_socket(%{live_action: :login})
      session = %{"user_token" => "invalid-token"}

      assert {:cont, updated_socket} = AuthLiveSessionHook.on_mount(@hook, %{}, session, socket)

      assert updated_socket.assigns.current_user == nil
    end
  end
end
