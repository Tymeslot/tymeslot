defmodule TymeslotWeb.Hooks.AnnouncementsHookTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :utils

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Announcements
  alias Tymeslot.AnnouncementsTestCatalog
  alias TymeslotWeb.Hooks.AnnouncementsHook

  setup do
    previous = Application.get_env(:tymeslot, :announcement_catalogs, [])

    Application.put_env(:tymeslot, :announcement_catalogs, [AnnouncementsTestCatalog])

    on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)

    :ok
  end

  describe "on_mount(:load_unseen_announcements, ...)" do
    test "assigns [] when the socket is not connected" do
      socket = %Socket{transport_pid: nil, assigns: %{__changed__: %{}, current_user: nil}}

      assert {:cont, %Socket{} = socket} =
               AnnouncementsHook.on_mount(:load_unseen_announcements, %{}, %{}, socket)

      assert socket.assigns.unseen_announcements == []
    end

    test "assigns [] when current_user is nil" do
      socket = %Socket{transport_pid: self(), assigns: %{__changed__: %{}, current_user: nil}}

      assert {:cont, %Socket{} = socket} =
               AnnouncementsHook.on_mount(:load_unseen_announcements, %{}, %{}, socket)

      assert socket.assigns.unseen_announcements == []
    end

    test "assigns the unseen announcements for an authenticated, connected user" do
      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])

      socket = %Socket{
        transport_pid: self(),
        assigns: %{__changed__: %{}, current_user: user}
      }

      assert {:cont, %Socket{} = socket} =
               AnnouncementsHook.on_mount(:load_unseen_announcements, %{}, %{}, socket)

      keys = Enum.map(socket.assigns.unseen_announcements, & &1.key)
      assert keys == ["test_alpha", "test_beta"]
    end

    test "assigns [] for a user who has seen everything" do
      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])
      Announcements.mark_seen!(user, "test_alpha")
      Announcements.mark_seen!(user, "test_beta")

      socket = %Socket{
        transport_pid: self(),
        assigns: %{__changed__: %{}, current_user: user}
      }

      assert {:cont, %Socket{} = socket} =
               AnnouncementsHook.on_mount(:load_unseen_announcements, %{}, %{}, socket)

      assert socket.assigns.unseen_announcements == []
    end
  end
end
