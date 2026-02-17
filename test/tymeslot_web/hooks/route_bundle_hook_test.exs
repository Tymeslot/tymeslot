defmodule TymeslotWeb.Hooks.RouteBundleHookTest do
  use TymeslotWeb.ConnCase, async: true

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

    test "always returns {:cont, socket} tuple for pipeline continuation" do
      socket = %Phoenix.LiveView.Socket{view: TymeslotWeb.AuthLive}
      result = RouteBundleHook.on_mount(:default, %{}, %{}, socket)

      assert match?({:cont, %Phoenix.LiveView.Socket{}}, result)
    end

    test "assigns appropriate bundles for all known dashboard LiveViews" do
      dashboard_views = [
        TymeslotWeb.DashboardLive,
        TymeslotWeb.AccountLive
      ]

      for view <- dashboard_views do
        socket = %Phoenix.LiveView.Socket{view: view}
        {:cont, updated_socket} = RouteBundleHook.on_mount(:default, %{}, %{}, socket)

        assert updated_socket.assigns.route_bundle == "dashboard",
               "Expected #{inspect(view)} to be assigned 'dashboard' bundle"
      end
    end

    test "assigns 'auth' bundle for all auth LiveViews" do
      # Currently only AuthLive, but this documents the pattern
      auth_views = [TymeslotWeb.AuthLive]

      for view <- auth_views do
        socket = %Phoenix.LiveView.Socket{view: view}
        {:cont, updated_socket} = RouteBundleHook.on_mount(:default, %{}, %{}, socket)

        assert updated_socket.assigns.route_bundle == "auth",
               "Expected #{inspect(view)} to be assigned 'auth' bundle"
      end
    end

    test "only returns allowlisted bundle names" do
      # Test that all known bundles are in the allowlist
      known_bundles = ["auth", "dashboard"]

      for bundle <- known_bundles do
        socket = %Phoenix.LiveView.Socket{
          view:
            case bundle do
              "auth" -> TymeslotWeb.AuthLive
              "dashboard" -> TymeslotWeb.DashboardLive
            end
        }

        {:cont, updated_socket} = RouteBundleHook.on_mount(:default, %{}, %{}, socket)
        assert updated_socket.assigns.route_bundle in (~w(auth dashboard public saas) ++ [nil])
      end
    end
  end
end
