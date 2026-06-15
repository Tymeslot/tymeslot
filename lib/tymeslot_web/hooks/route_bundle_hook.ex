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
  def on_mount(:default, _params, _session, socket) do
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
  # Security: Only returns allowlisted bundle names to prevent arbitrary script loading.
  #
  # @allowed_bundles deliberately lists more bundle names than determine_bundle/1
  # currently returns ("public"/"saas" have no producing clause yet) so that any
  # future bundle wired into the case below is validated against the allowlist
  # automatically. OTP 28's dialyzer flags the resulting never-true comparisons as
  # `:exact_compare`; the redundancy is intentional defence-in-depth, so the
  # allowlist must not be narrowed to silence it. dialyxir 1.4.7 cannot pretty-print
  # the `:exact_compare` subtype nor filter it via .dialyzer_ignore.exs, so we
  # suppress it at the engine level here.
  @allowed_bundles ~w(auth dashboard public saas)
  @dialyzer {:nowarn_function, determine_bundle: 1}
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
        _module ->
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
