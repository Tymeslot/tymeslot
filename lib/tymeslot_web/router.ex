defmodule TymeslotWeb.Router do
  use TymeslotWeb, :router

  # =============================================================================
  # Pipelines
  # =============================================================================

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TymeslotWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug TymeslotWeb.Plugs.SecurityHeadersPlug
    plug TymeslotWeb.Plugs.FetchCurrentUser
    plug TymeslotWeb.Plugs.ThemePlug
  end

  pipeline :theme_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TymeslotWeb.Layouts, :scheduling_root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug TymeslotWeb.Plugs.SecurityHeadersPlug
    plug TymeslotWeb.Plugs.FetchCurrentUser
    plug TymeslotWeb.Plugs.ThemePlug
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug TymeslotWeb.Plugs.SecurityHeadersPlug
  end

  pipeline :main_deployment_only do
    plug TymeslotWeb.Plugs.EnsureMainDeploymentPlug
  end

  pipeline :require_authenticated_user do
    plug TymeslotWeb.Plugs.RequireAuthPlug
  end

  # =============================================================================
  # Healthcheck (early to avoid wildcard username routes)
  # =============================================================================

  scope "/", TymeslotWeb do
    pipe_through :api

    get "/healthcheck", HealthcheckController, :index
  end

  # =============================================================================
  # Public Routes
  # =============================================================================

  # Root and general public routes
  scope "/", TymeslotWeb do
    pipe_through :browser

    # Root path - runtime deployment detection and user routing
    get "/", RootRedirectController, :index
  end

  # Main deployment only routes
  scope "/", TymeslotWeb do
    pipe_through [:browser, :main_deployment_only]

    live "/contact", ContactLive
    live "/legal/:document_type", Legal.LegalDocumentLive
  end

  # =============================================================================
  # Authentication Routes
  # =============================================================================

  scope "/", TymeslotWeb do
    pipe_through :browser

    # LiveView authentication routes
    live "/auth/login", AuthLive, :login
    live "/auth/signup", AuthLive, :signup
    live "/auth/verify-email", AuthLive, :verify_email
    live "/auth/reset-password", AuthLive, :reset_password
    live "/auth/reset-password-sent", AuthLive, :reset_password_sent
    live "/auth/reset-password/:token", AuthLive, :reset_password_form
    live "/auth/complete-registration", AuthLive, :complete_registration
    live "/auth/password-reset-success", AuthLive, :password_reset_success

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

    live_session :authenticated,
      on_mount: [
        {Tymeslot.LiveHooks.AuthLiveSessionHook, :ensure_authenticated},
        TymeslotWeb.Hooks.ClientInfoHook
      ] do
      live "/dashboard", DashboardLive, :overview
      live "/dashboard/settings", DashboardLive, :settings
      live "/dashboard/availability", DashboardLive, :availability
      live "/dashboard/account", AccountLive
      live "/dashboard/meeting-settings", DashboardLive, :meeting_settings
      live "/dashboard/calendar", DashboardLive, :calendar
      live "/dashboard/video", DashboardLive, :video
      live "/dashboard/theme", DashboardLive, :theme
      live "/dashboard/meetings", DashboardLive, :meetings
      live "/dashboard/payment", DashboardLive, :payment
    end
  end

  # Onboarding routes
  scope "/", TymeslotWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :onboarding,
      on_mount: [
        {Tymeslot.LiveHooks.AuthLiveSessionHook, :ensure_authenticated},
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
      on_mount: [TymeslotWeb.Hooks.ThemeHook, TymeslotWeb.Hooks.ClientInfoHook] do
      live "/:username/meeting/:meeting_uid/cancel", Themes.Core.Dispatcher, :cancel

      live "/:username/meeting/:meeting_uid/cancel-confirmed",
           Themes.Core.Dispatcher,
           :cancel_confirmed

      live "/:username/meeting/:meeting_uid/reschedule", Themes.Core.Dispatcher, :reschedule
    end
  end

  # Username-based scheduling routes (must be before catch-all)
  scope "/", TymeslotWeb do
    pipe_through [:theme_browser, TymeslotWeb.Plugs.DemoUsernamePlug]

    live_session :username_scheduling,
      on_mount: [TymeslotWeb.Hooks.ThemeHook, TymeslotWeb.Hooks.ClientInfoHook] do
      live "/:username", Themes.Core.Dispatcher, :overview
      live "/:username/schedule/:duration", Themes.Core.Dispatcher, :schedule
      live "/:username/schedule/:duration/book", Themes.Core.Dispatcher, :booking
      live "/:username/schedule/thank-you", Themes.Core.Dispatcher, :confirmation
    end
  end

  # =============================================================================
  # API Routes
  # =============================================================================
  # =============================================================================
  # Development Routes
  # =============================================================================

  if Application.compile_env(:tymeslot, :dev_routes) do
    pipeline :local_only do
      plug TymeslotWeb.Plugs.EnsureLocalAccessPlug
    end

    # Swoosh mailbox preview
    scope "/dev" do
      pipe_through :browser
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    # Debug routes
    scope "/debug", TymeslotWeb do
      pipe_through [:browser, :local_only, :require_authenticated_user]

      live_session :debug_onboarding,
        on_mount: [{Tymeslot.LiveHooks.AuthLiveSessionHook, :ensure_authenticated}] do
        live "/onboarding", OnboardingLive, :debug_welcome
        live "/onboarding/:step", OnboardingLive, :debug_step
      end
    end
  end

  # =============================================================================
  # Catch-all Route
  # =============================================================================

  scope "/", TymeslotWeb do
    pipe_through :browser

    get "/*path", FallbackController, :index
  end
end
