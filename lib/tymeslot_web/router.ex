defmodule TymeslotWeb.Router do
  use TymeslotWeb, :router

  require Logger

  alias Plug.Conn

  # =============================================================================
  # Healthcheck (early to avoid wildcard username routes)
  # =============================================================================

  scope "/", TymeslotWeb do
    pipe_through :api

    get "/healthcheck", HealthcheckController, :index
  end

  # =============================================================================
  # Webhook Routes
  # =============================================================================

  scope "/webhooks", TymeslotWeb do
    pipe_through :webhook

    post "/stripe", StripeWebhookController, :webhook
  end

  scope "/webhooks", TymeslotWeb do
    pipe_through :api

    post "/google-calendar", GoogleCalendarWebhookController, :webhook
    post "/outlook-calendar", OutlookCalendarWebhookController, :webhook
    post "/outlook-lifecycle", OutlookLifecycleController, :webhook
  end

  # Telegram bot webhook (unauthenticated, outside :browser pipeline)
  scope "/api/telegram", TymeslotWeb do
    pipe_through :api

    post "/webhook", TelegramWebhookController, :webhook
  end

  # Slack OAuth start/callback (authenticated browser flow — the user must be
  # logged in to begin the dance and the callback needs the session cookie to
  # redirect them back to /dashboard/automation).
  scope "/api/slack", TymeslotWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/oauth/start", SlackOAuthController, :start
    get "/oauth/callback", SlackOAuthController, :callback
  end

  # =============================================================================
  # Dev-Only Routes
  # =============================================================================

  if Mix.env() == :dev do
    scope "/dev", TymeslotWeb.Dev do
      pipe_through :browser

      get "/embed-test", EmbedTestController, :index
    end

    scope "/dev", TymeslotWeb do
      pipe_through :browser

      live_session :dev_announcements_preview do
        live "/announcements", Dev.AnnouncementsPreviewLive, :index
      end
    end

    scope "/dev", TymeslotWeb do
      pipe_through [:browser, :require_authenticated_user]

      live_session :dev_onboarding,
        on_mount: [
          {TymeslotWeb.Hooks.AuthLiveSessionHook, :ensure_authenticated},
          TymeslotWeb.Hooks.ClientInfoHook
        ] do
        live "/onboarding", OnboardingLive, :debug_welcome
        live "/onboarding/:step", OnboardingLive, :debug_step
      end
    end
  end

  # =============================================================================
  # Core Root Route
  # =============================================================================

  scope "/", TymeslotWeb do
    pipe_through :browser

    get "/", RootRedirectController, :index
  end

  # =============================================================================
  # Authentication Routes
  # =============================================================================

  scope "/", TymeslotWeb do
    pipe_through :browser

    # LiveView authentication routes with route bundle loading
    live_session :auth,
      on_mount: [TymeslotWeb.Hooks.RouteBundleHook] do
      live "/auth/login", AuthLive, :login
      live "/auth/signup", AuthLive, :signup
      live "/auth/verify-email", AuthLive, :verify_email
      live "/auth/reset-password", AuthLive, :reset_password
      live "/auth/reset-password-sent", AuthLive, :reset_password_sent
      live "/auth/reset-password/:token", AuthLive, :reset_password_form
      live "/auth/complete-registration", AuthLive, :complete_registration
      live "/auth/password-reset-success", AuthLive, :password_reset_success
    end

    # Email change verification route
    get "/email-change/:token", EmailChangeController, :verify

    # OAuth routes (must remain as controllers for external redirects)
    get "/auth/:provider", OAuthController, :request
    get "/auth/:provider/callback", OAuthController, :callback
    post "/auth/complete", OAuthController, :complete

    # Calendar OAuth routes
    get "/auth/google/calendar/callback", CalendarOAuthController, :google_callback
    get "/auth/outlook/calendar/callback", CalendarOAuthController, :outlook_callback

    # Video OAuth routes
    get "/auth/google/video/callback", VideoOAuthController, :google_callback
    get "/auth/teams/video/callback", VideoOAuthController, :teams_callback

    # Session management routes
    post "/auth/session", SessionController, :create
    delete "/auth/logout", SessionController, :delete
    get "/auth/verify-complete/:token", SessionController, :verify_and_login
  end

  # =============================================================================
  # Authenticated Routes
  # =============================================================================

  # Dashboard routes
  scope "/", TymeslotWeb do
    pipe_through [:browser, :require_authenticated_user]

    @dashboard_hooks [
      {TymeslotWeb.Hooks.AuthLiveSessionHook, :ensure_authenticated},
      TymeslotWeb.Hooks.ClientInfoHook,
      TymeslotWeb.Hooks.DashboardInitHook,
      {TymeslotWeb.Hooks.FeatureAssignsHook, :set_feature_assigns},
      TymeslotWeb.Hooks.RouteBundleHook
    ]

    @spec on_mount(
            :dashboard_hooks,
            map(),
            map(),
            Phoenix.LiveView.Socket.t()
          ) :: {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
    def on_mount(:dashboard_hooks, params, session, socket) do
      hooks =
        @dashboard_hooks ++
          dashboard_additional_hooks() ++
          [{TymeslotWeb.Hooks.AnnouncementsHook, :load_unseen_announcements}]

      Enum.reduce_while(hooks, {:cont, socket}, fn
        {module, function}, {:cont, socket} ->
          case module.on_mount(function, params, session, socket) do
            {:cont, socket} -> {:cont, {:cont, socket}}
            {:halt, socket} -> {:halt, {:halt, socket}}
          end

        module, {:cont, socket} when is_atom(module) ->
          case module.on_mount(:default, params, session, socket) do
            {:cont, socket} -> {:cont, {:cont, socket}}
            {:halt, socket} -> {:halt, {:halt, socket}}
          end

        _other, {:cont, socket} ->
          {:cont, {:cont, socket}}
      end)
    end

    @doc false
    @spec dashboard_additional_hooks() :: list()
    def dashboard_additional_hooks do
      case Application.get_env(:tymeslot, :dashboard_additional_hooks, []) do
        hooks when is_list(hooks) ->
          hooks

        hook when is_tuple(hook) or is_atom(hook) ->
          Logger.warning(
            "Expected :dashboard_additional_hooks to be a list, received a single hook. Wrapping."
          )

          [hook]

        other ->
          Logger.warning(
            "Expected :dashboard_additional_hooks to be a list; ignoring invalid value",
            value: inspect(other)
          )

          []
      end
    end

    live_session :authenticated,
      on_mount: {__MODULE__, :dashboard_hooks} do
      live "/dashboard", DashboardLive, :overview
      live "/dashboard/settings", DashboardLive, :settings
      live "/dashboard/availability", DashboardLive, :availability
      live "/dashboard/account", AccountLive
      live "/dashboard/meeting-settings", DashboardLive, :meeting_settings
      live "/dashboard/calendar", DashboardLive, :calendar
      live "/dashboard/calendar-integration", DashboardLive, :calendar_integration
      live "/dashboard/video-integration", DashboardLive, :video_integration
      live "/dashboard/automation", DashboardLive, :automation
      live "/dashboard/theme", DashboardLive, :theme
      live "/dashboard/theme/customize/:theme_id", DashboardLive, :theme_customization
      live "/dashboard/meetings", DashboardLive, :meetings
      live "/dashboard/embed", DashboardLive, :embed
    end
  end

  # =============================================================================
  # Admin Routes (self-hosted only — locked down in SaaS via enable_admin_ui)
  # =============================================================================
  scope "/admin", TymeslotWeb do
    pipe_through [
      :browser,
      :require_authenticated_user,
      TymeslotWeb.Plugs.RequireAdminUiEnabled,
      TymeslotWeb.Plugs.RequireAdmin
    ]

    live_session :admin,
      on_mount: [
        {TymeslotWeb.Hooks.AuthLiveSessionHook, :ensure_authenticated},
        TymeslotWeb.Hooks.EnsureAdminHook
      ] do
      live "/", AdminLive, :settings
      live "/settings", AdminLive, :settings
      live "/users", AdminLive, :users
    end
  end

  # Onboarding routes
  scope "/", TymeslotWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :onboarding,
      on_mount: [
        {TymeslotWeb.Hooks.AuthLiveSessionHook, :ensure_authenticated},
        TymeslotWeb.Hooks.ClientInfoHook
      ] do
      live "/onboarding", OnboardingLive, :welcome
      live "/onboarding/:step", OnboardingLive, :step
    end
  end

  # =============================================================================
  # Theme/Scheduling Routes
  # =============================================================================

  # Meeting management routes
  scope "/", TymeslotWeb do
    pipe_through :theme_browser

    live_session :meeting_management,
      on_mount: [
        TymeslotWeb.Hooks.LocaleHook,
        TymeslotWeb.Hooks.ThemeHook,
        TymeslotWeb.Hooks.ClientInfoHook
      ] do
      live "/:username/meeting/:meeting_uid/cancel", Themes.Core.Dispatcher, :cancel

      live "/:username/meeting/:meeting_uid/cancel-confirmed",
           Themes.Core.Dispatcher,
           :cancel_confirmed

      live "/:username/meeting/:meeting_uid/reschedule", Themes.Core.Dispatcher, :reschedule
    end
  end

  # Username-based scheduling routes (must be before catch-all)
  scope "/", TymeslotWeb do
    pipe_through :theme_browser

    live_session :username_scheduling,
      session: {__MODULE__, :scheduling_session, []},
      on_mount: [
        TymeslotWeb.Hooks.EmbedAuthHook,
        TymeslotWeb.Hooks.LocaleHook,
        TymeslotWeb.Hooks.ThemeHook,
        TymeslotWeb.Hooks.ClientInfoHook
      ] do
      live "/:username", Themes.Core.Dispatcher, :overview
      live "/:username/thank-you", Themes.Core.Dispatcher, :confirmation
      live "/:username/:slug", Themes.Core.Dispatcher, :schedule
      live "/:username/:slug/book", Themes.Core.Dispatcher, :booking
    end
  end

  # =============================================================================
  # API Routes
  # =============================================================================
  # =============================================================================
  # Catch-all Route
  # =============================================================================

  scope "/", TymeslotWeb do
    pipe_through :browser

    get "/*path", FallbackController, :index
  end

  @doc false
  @spec scheduling_session(Plug.Conn.t()) :: map()
  def scheduling_session(conn) do
    %{
      "locale" => Conn.get_session(conn, "locale"),
      "embed_token" => conn.assigns[:embed_token]
    }
  end
end
