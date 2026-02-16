defmodule TymeslotWeb.Hooks.RouteBundleHook do
  @moduledoc """
  Assigns the appropriate JavaScript bundle based on the current route.

  This enables route-based code splitting by loading only the JavaScript
  needed for the current page section.

  Bundles:
  - `auth` - Auth pages (/auth/*)
  - `dashboard` - Dashboard pages (/dashboard/*)
  - `public` - Public booking pages (uses scheduling_root layout directly)
  - `nil` - No additional bundle (core only)
  """

  import Phoenix.Component

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _, _, socket) do
    bundle = determine_bundle(socket.view)
    {:cont, assign(socket, :route_bundle, bundle)}
  end

  # Use pattern matching on full module names for robustness
  # This is safer than string parsing and more maintainable
  #
  # IMPORTANT: When adding new LiveView modules to the :authenticated or :auth
  # live_sessions, update this function to assign the appropriate bundle.
  # Otherwise, the LiveView will get `nil` and route-specific hooks won't be registered.
  #
  # Bundles:
  # - "auth" -> Auth-specific hooks (PasswordToggle, RecaptchaV3, AuthVideo)
  # - "dashboard" -> Dashboard hooks (AutoUpload, EmbedPreview, MeetingTypeSortable)
  # - "public" -> Public booking hooks (loaded via scheduling_root layout directly)
  # - nil -> Core hooks only
  #
  # Security: Only returns allowlisted bundle names to prevent arbitrary script loading
  @allowed_bundles ~w(auth dashboard public saas)
  defp determine_bundle(view_module) do
    bundle =
      case view_module do
        # Auth pages
        TymeslotWeb.AuthLive ->
          "auth"

        # Dashboard pages
        TymeslotWeb.DashboardLive ->
          "dashboard"

        TymeslotWeb.AccountLive ->
          "dashboard"

        # Onboarding uses a separate live_session without route bundle
        TymeslotWeb.OnboardingLive ->
          nil

        # Public booking uses scheduling_root layout (handles bundle itself)
        # SchedulingLive is in its own namespace
        _ ->
          nil
      end

    # Validate against allowlist as defense-in-depth
    if bundle && bundle not in @allowed_bundles do
      raise ArgumentError,
            "Invalid bundle name: #{inspect(bundle)}. Must be one of: #{inspect(@allowed_bundles)}"
    end

    bundle
  end
end
