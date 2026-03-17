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

  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets css fonts icons images uploads videos embed.js)

  @spec router() :: Macro.t()
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

      pipeline :api do
        plug :accepts, ["json"]
        plug TymeslotWeb.Plugs.SecurityHeadersPlug
      end

      pipeline :webhook do
        plug TymeslotWeb.Plugs.StripeWebhookPlug
        plug :accepts, ["json"]
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
