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

  # Public free/busy feed — token-gated, declared early so it wins over the
  # wildcard username booking routes.
  scope "/", TymeslotWeb do
    pipe_through :public_feed

    get "/free-busy/:token", FreebusyController, :index
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

    post "/stripe/connect", StripeConnectWebhookController, :handle
  end

  # Calendar provider webhooks negotiate `text/plain` for their subscription
  # validation handshake, so they run through `:calendar_webhook` rather than the
  # json-only `:api` pipeline (which would 406 the handshake — see tymeslot_web.ex).
  scope "/webhooks", TymeslotWeb do
    pipe_through :calendar_webhook

    post "/google-calendar", GoogleCalendarWebhookController, :webhook
    post "/outlook-calendar", OutlookCalendarWebhookController, :webhook
    post "/outlook-lifecycle", OutlookLifecycleController, :webhook
  end

  # Zoom app deauthorization endpoint — POSTed by Zoom when a user uninstalls
  # the Marketplace app. Lives under /auth to mirror the OAuth callback path
  # and runs through the unauthenticated :api pipeline (no CSRF).
  scope "/", TymeslotWeb do
    pipe_through :api

    post "/auth/zoom/deauthorize", ZoomDeauthController, :deauthorize
  end

  # Telegram bot webhook (unauthenticated, outside :browser pipeline)
  scope "/api/telegram", TymeslotWeb do
    pipe_through :api

    post "/webhook", TelegramWebhookController, :webhook
  end

  # Booking creation for external systems (CRMs, automation platforms). Every
  # request carries the organiser's booking API token in an `Authorization:
  # Bearer` header, so it runs outside the session-based pipelines — see
  # `TymeslotWeb.BookingApiController`.
  scope "/api/v1", TymeslotWeb do
    pipe_through :api

    post "/bookings", BookingApiController, :create
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

  if Application.compile_env(:tymeslot, :dev_routes, false) do
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
      on_mount: [TymeslotWeb.Hooks.LocaleHook, TymeslotWeb.Hooks.RouteBundleHook] do
      live "/auth/login", AuthLive, :login
      live "/auth/signup", AuthLive, :signup
      live "/auth/verify-email", AuthLive, :verify_email
      live "/auth/reset-password", AuthLive, :reset_password
      live "/auth/reset-password-sent", AuthLive, :reset_password_sent
      live "/auth/reset-password/:token", AuthLive, :reset_password_form
      live "/auth/complete-registration", AuthLive, :complete_registration
      live "/auth/password-reset-success", AuthLive, :password_reset_success
    end

    # Convenience redirects for mistyped auth slugs. Defined before the
    # `/:username` booking-page catch-all so they resolve here rather than as a
    # username lookup. See TymeslotWeb.AuthAliasController.
    get "/login", AuthAliasController, :login
    get "/signin", AuthAliasController, :login
    get "/sign-in", AuthAliasController, :login
    get "/signup", AuthAliasController, :signup
    get "/sign-up", AuthAliasController, :signup
    get "/register", AuthAliasController, :signup

    # Email change verification route
    get "/email-change/:token", EmailChangeController, :verify

    # Public guest RSVP (accept/decline) from the tokenised email link.
    # GET renders a confirmation landing page (no mutation — safe for link prefetchers).
    # POST performs the RSVP write (CSRF-protected via the :browser pipeline).
    get "/guest/:token/:response", GuestRsvpController, :confirm
    post "/guest/:token/:response", GuestRsvpController, :submit

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
    get "/auth/zoom/video/callback", VideoOAuthController, :zoom_callback

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
      TymeslotWeb.Hooks.AppLocaleHook,
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
      live "/dashboard", DashboardLive, :calendar
      live "/dashboard/overview", DashboardLive, :overview
      live "/dashboard/settings", DashboardLive, :settings
      live "/dashboard/availability", DashboardLive, :availability
      live "/dashboard/account", AccountLive
      live "/dashboard/meeting-settings", DashboardLive, :meeting_settings
      live "/dashboard/calendar", DashboardLive, :calendar
      live "/dashboard/calendar-integration", DashboardLive, :calendar_integration
      live "/dashboard/video-integration", DashboardLive, :video_integration
      live "/dashboard/integrations", DashboardLive, :integrations
      live "/dashboard/automation", DashboardLive, :automation
      live "/dashboard/theme", DashboardLive, :theme
      live "/dashboard/theme/customize/:theme_id", DashboardLive, :theme_customization
      live "/dashboard/meetings", DashboardLive, :meetings
      live "/dashboard/polls", DashboardLive, :polls
      live "/dashboard/embed", DashboardLive, :embed
      live "/dashboard/analytics", Dashboard.AnalyticsLive, :index
      live "/dashboard/payments", DashboardLive, :payments
    end

    post "/dashboard/payments/connect", Dashboard.PaymentsController, :connect
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
        TymeslotWeb.Hooks.AppLocaleHook,
        TymeslotWeb.Hooks.EnsureAdminHook
      ] do
      # One route per tab; `TymeslotWeb.AdminLive.Tabs` is the list these must
      # match. `/settings` is kept as an alias for the old single-tab URL so
      # existing bookmarks still land somewhere sensible.
      live "/", AdminLive, :authentication
      live "/settings", AdminLive, :authentication
      live "/authentication", AdminLive, :authentication
      live "/email", AdminLive, :email
      live "/general", AdminLive, :general
      live "/users", AdminLive, :users
    end
  end

  # Onboarding routes
  scope "/", TymeslotWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :onboarding,
      on_mount: [
        {TymeslotWeb.Hooks.AuthLiveSessionHook, :ensure_authenticated},
        TymeslotWeb.Hooks.AppLocaleHook,
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

  # Theme-aware payment return pages (Stripe Checkout success/cancel)
  scope "/", TymeslotWeb do
    pipe_through :theme_browser

    live_session :payment_return,
      on_mount: [
        TymeslotWeb.Hooks.LocaleHook,
        TymeslotWeb.Hooks.ClientInfoHook
      ] do
      live "/themes/quill/payment-processing/:meeting_id",
           Themes.Quill.PaymentProcessingLive

      live "/themes/quill/payment-cancelled/:meeting_id",
           Themes.Quill.PaymentCancelledLive

      live "/themes/rhythm/payment-processing/:meeting_id",
           Themes.Rhythm.PaymentProcessingLive

      live "/themes/rhythm/payment-cancelled/:meeting_id",
           Themes.Rhythm.PaymentCancelledLive
    end
  end

  # Public notice shown inside the iframe when an embed is rejected (the
  # embedding origin isn't allow-listed). Must be declared before the
  # `/:username` catch-all so it isn't shadowed by a username route, and runs
  # through its own pipeline so it frames on any origin.
  scope "/", TymeslotWeb do
    pipe_through :embed_notice

    get "/embed-unavailable", EmbedBlockedController, :index
  end

  # Public per-meeting calendar download (.ics). Access is gated by the
  # unguessable meeting UID scoped to the organiser's username (IDOR-safe).
  # Runs through :public_feed (accepts the `ics` format) and must be declared
  # before the `/:username` catch-all so it isn't shadowed by a username route.
  scope "/", TymeslotWeb do
    pipe_through :public_feed

    get "/:username/meeting/:meeting_uid/calendar.ics", MeetingCalendarController, :show
  end

  # Public poll voting page. Declared before `:username_scheduling` so the
  # `/:username/poll/:token` route is matched ahead of the `/:username/:slug`
  # scheduling catch-all, which would otherwise swallow it.
  scope "/", TymeslotWeb do
    pipe_through :theme_browser

    live_session :poll_voting,
      on_mount: [
        TymeslotWeb.Hooks.LocaleHook,
        TymeslotWeb.Hooks.ThemeHook,
        TymeslotWeb.Hooks.ClientInfoHook
      ] do
      live "/:username/poll/:token", Themes.Core.Dispatcher, :poll_voting
    end
  end

  # Username-based scheduling routes (must be before catch-all)
  scope "/", TymeslotWeb do
    pipe_through [:theme_browser, TymeslotWeb.Plugs.CaptureReferrerPlug]

    live_session :username_scheduling,
      session: {__MODULE__, :scheduling_session, []},
      on_mount: [
        TymeslotWeb.Hooks.EmbedAuthHook,
        TymeslotWeb.Hooks.LocaleHook,
        TymeslotWeb.Hooks.ThemeHook,
        TymeslotWeb.Hooks.ClientInfoHook,
        TymeslotWeb.Hooks.PageViewHook
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
      "embed_token" => conn.assigns[:embed_token],
      "scheduling_referrer" => Conn.get_session(conn, "scheduling_referrer"),
      # Forwarded so PageViewHook can recognise an organizer viewing their own
      # booking page and skip logging that self-visit. Resolved to a user off
      # the mount path, inside the async page-view Task.
      "user_token" => Conn.get_session(conn, "user_token")
    }
  end
end
