defmodule TymeslotWeb.Hooks.RouteBundleHookTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

  alias TymeslotWeb.Hooks.RouteBundleHook

  describe "on_mount/4" do
    test "assigns 'auth' bundle for AuthLive" do
      socket = %Phoenix.LiveView.Socket{view: TymeslotWeb.AuthLive}
      {:cont, updated_socket} = RouteBundleHook.on_mount(:default, %{}, %{}, socket)

      assert updated_socket.assigns.route_bundle == "auth"
    end

    test "assigns 'dashboard' bundle for DashboardLive" do
      socket = %Phoenix.LiveView.Socket{view: TymeslotWeb.DashboardLive}
      {:cont, updated_socket} = RouteBundleHook.on_mount(:default, %{}, %{}, socket)

      assert updated_socket.assigns.route_bundle == "dashboard"
    end

    test "assigns 'dashboard' bundle for AccountLive" do
      socket = %Phoenix.LiveView.Socket{view: TymeslotWeb.AccountLive}
      {:cont, updated_socket} = RouteBundleHook.on_mount(:default, %{}, %{}, socket)

      assert updated_socket.assigns.route_bundle == "dashboard"
    end

    test "assigns nil bundle for OnboardingLive" do
      socket = %Phoenix.LiveView.Socket{view: TymeslotWeb.OnboardingLive}
      {:cont, updated_socket} = RouteBundleHook.on_mount(:default, %{}, %{}, socket)

      assert updated_socket.assigns.route_bundle == nil
    end

    test "assigns nil bundle for unknown LiveView" do
      # Create a fake module name that doesn't match any patterns
      defmodule FakeUnknownLive do
      end

      socket = %Phoenix.LiveView.Socket{view: __MODULE__.FakeUnknownLive}
      {:cont, updated_socket} = RouteBundleHook.on_mount(:default, %{}, %{}, socket)

      assert updated_socket.assigns.route_bundle == nil
    end
  end
end
