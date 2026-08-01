defmodule TymeslotWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use TymeslotWeb, :controller
      use TymeslotWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  # favicon.ico sits at the root rather than being linked from <head>. Chrome
  # downloads a linked .ico on every page load even alongside an SVG icon it
  # prefers, and even when the link carries `type`; served from the well-known
  # root path it is requested only by the browsers that actually need it —
  # those without SVG favicon support, which look there by default.
  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets css fonts icons images uploads videos embed.js favicon.ico)

  @spec router() :: Macro.t()
  # The router macro is a declarative list of HTTP/LiveView pipelines; ABC
  # complexity counts each `plug` as a branch, which overstates the real
  # cognitive complexity. Suppress here rather than fracture the macro with
  # indirection purely to satisfy the metric.
  # credo:disable-for-next-line Credo.Check.Refactor.ABCSize
  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router

      # =============================================================================
      # Shared Pipelines
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
        plug TymeslotWeb.Plugs.SetLoggerMetadata
        plug TymeslotWeb.Plugs.LocalePlug, prefer_user_locale: true
        plug TymeslotWeb.Plugs.ThemePlug
      end

      pipeline :theme_browser do
        plug TymeslotWeb.Plugs.RejectStaticPathsPlug
        plug :accepts, ["html"]
        plug :fetch_session
        plug :fetch_live_flash
        plug :put_root_layout, html: {TymeslotWeb.Layouts, :scheduling_root}
        plug :protect_from_forgery
        plug :put_secure_browser_headers
        plug TymeslotWeb.Plugs.SecurityHeadersPlug, allow_embedding: true
        plug TymeslotWeb.Plugs.EmbedTokenPlug
        plug TymeslotWeb.Plugs.FetchCurrentUser
        plug TymeslotWeb.Plugs.SetLoggerMetadata
        plug TymeslotWeb.Plugs.LocalePlug
        plug TymeslotWeb.Plugs.ThemePlug
        plug TymeslotWeb.Plugs.ThemeProtectionPlug
      end

      # Minimal pipeline for the public, content-free embed-unavailable notice.
      # SecurityHeadersPlug runs in `:any` mode so the page frames on ANY
      # origin (including ones embedding is blocked on) — that's the whole
      # point: it replaces the marketing-homepage fallback inside the iframe.
      pipeline :embed_notice do
        plug :accepts, ["html"]
        plug :put_secure_browser_headers
        plug TymeslotWeb.Plugs.SecurityHeadersPlug, allow_embedding: :any
      end

      pipeline :api do
        plug :accepts, ["json"]
        plug TymeslotWeb.Plugs.SecurityHeadersPlug
        plug TymeslotWeb.Plugs.SetLoggerMetadata
      end

      # Calendar providers (Microsoft Graph, Google) confirm a new push
      # subscription with a synchronous validation handshake: they call the
      # notification URL and negotiate for `text/plain`, expecting the challenge
      # token echoed back verbatim. The json-only `:api` pipeline rejects that
      # request with `406 Not Acceptable`, so the provider abandons the
      # subscription with an `HTTP 400` validation error. Accepting `text/plain`
      # alongside `json` lets the handshake through to the controller.
      pipeline :calendar_webhook do
        plug :accepts, ["json", "txt"]
        plug TymeslotWeb.Plugs.SecurityHeadersPlug
        plug TymeslotWeb.Plugs.SetLoggerMetadata
      end

      pipeline :webhook do
        plug TymeslotWeb.Plugs.StripeWebhookPlug
        plug :accepts, ["json"]
        plug TymeslotWeb.Plugs.SetLoggerMetadata
      end

      # Public, unauthenticated iCalendar feed (free/busy). Calendar clients
      # subscribe with `Accept: text/calendar` (the `ics` format) or `*/*`, so
      # the json-only `:api` pipeline would `406` them.
      pipeline :public_feed do
        plug :accepts, ["ics", "txt", "json"]
        plug TymeslotWeb.Plugs.SecurityHeadersPlug
        plug TymeslotWeb.Plugs.SetLoggerMetadata
      end

      pipeline :require_authenticated_user do
        plug TymeslotWeb.Plugs.RequireAuthPlug
      end
    end
  end

  @spec channel() :: Macro.t()
  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  @spec controller() :: Macro.t()
  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: TymeslotWeb.Layouts]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @spec live_view() :: Macro.t()
  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {TymeslotWeb.Layouts, :app}

      on_mount TymeslotWeb.Hooks.LoggerMetadataHook

      unquote(html_helpers())
    end
  end

  @spec live_component() :: Macro.t()
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @spec html() :: Macro.t()
  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import TymeslotWeb.Components.CoreComponents
      import TymeslotWeb.StepNavigation

      # Shortcut for generating JS commands
      alias Phoenix.LiveView.JS

      # Shared helpers
      alias TymeslotWeb.Hooks.ModalHook
      alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
      alias TymeslotWeb.Live.Shared.Flash

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  @spec verified_routes() :: Macro.t()
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: TymeslotWeb.Endpoint,
        router: TymeslotWeb.Router,
        statics: TymeslotWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
