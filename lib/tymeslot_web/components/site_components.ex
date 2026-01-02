defmodule TymeslotWeb.Components.SiteComponents do
  @moduledoc """
  Site-wide components for navigation, footer, and other shared UI elements.
  """
  use Phoenix.Component

  # Import the route helpers
  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  # Import JS helpers for LiveView interactions
  alias Phoenix.LiveView.JS
  alias Tymeslot.Deployment

  @doc """
  Main navigation component used across the application.
  """
  attr :current_user, :map, default: nil

  @spec navigation(map()) :: Phoenix.LiveView.Rendered.t()
  def navigation(assigns) do
    ~H"""
    <nav class="glass-nav">
      <div class="container mx-auto flex justify-between items-center">
        <.link
          navigate={logo_link(@current_user)}
          class="flex items-center space-x-2 text-gray-800 text-2xl font-bold hover:text-turquoise-600 transition-colors"
        >
          <img src="/images/brand/logo.svg" alt="Tymeslot" class="h-8 flex-shrink-0" />
          <span>Tymeslot</span>
        </.link>
        
    <!-- Desktop Navigation -->
        <div class="hidden md:flex items-center gap-6">
          <%= if @current_user do %>
            <.link navigate={~p"/dashboard"} class="simple-nav-link">
              Dashboard
            </.link>
            <.link href={~p"/auth/logout"} method="delete" class="simple-nav-link">
              Logout
            </.link>
          <% else %>
            <.link href={~p"/auth/login"} class="simple-nav-link">
              Login
            </.link>
            <.link href={~p"/auth/signup"} class="glass-button">
              Get Started
            </.link>
          <% end %>
        </div>
        
    <!-- Mobile Menu Button -->
        <button
          class="md:hidden mobile-menu-toggle flex items-center justify-center w-10 h-10 rounded-lg hover:bg-white/20 transition-colors"
          phx-click={
            JS.toggle(to: "#mobile-menu")
            |> JS.toggle_class("mobile-menu-open", to: ".mobile-menu-toggle")
          }
          aria-label="Toggle menu"
        >
          <svg class="w-6 h-6 text-gray-800" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 6h16M4 12h16M4 18h16"
            >
            </path>
          </svg>
        </button>
        
    <!-- Mobile Menu -->
        <div
          id="mobile-menu"
          class="mobile-menu md:hidden absolute top-full left-0 right-0 bg-white/95 backdrop-blur-md border-t border-gray-200 shadow-lg hidden"
        >
          <div class="container mx-auto px-4 py-4 space-y-3">
            <%= if @current_user do %>
              <.link
                navigate={~p"/dashboard"}
                class="mobile-nav-link block px-4 py-3 text-gray-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
              >
                Dashboard
              </.link>
              <.link
                href={~p"/auth/logout"}
                method="delete"
                class="mobile-nav-link block px-4 py-3 text-gray-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
              >
                Logout
              </.link>
            <% else %>
              <.link
                href={~p"/auth/login"}
                class="mobile-nav-link block px-4 py-3 text-gray-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
              >
                Login
              </.link>
              <.link
                href={~p"/auth/signup"}
                class="mobile-nav-button block px-4 py-3 bg-turquoise-600 text-white text-center rounded-lg hover:bg-turquoise-700 transition-colors"
              >
                Get Started
              </.link>
            <% end %>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  @doc """
  Site footer component with legal links.
  """
  @spec site_footer(map()) :: Phoenix.LiveView.Rendered.t()
  def site_footer(assigns) do
    ~H"""
    <footer class="mt-auto py-12 px-6 bg-gradient-to-r from-gray-900 to-gray-800">
      <div class="container mx-auto flex flex-col items-center gap-6">
        <div class="text-center">
          <p class="text-gray-400 mb-2">
            © {DateTime.utc_now().year} Tymeslot. All rights reserved.
          </p>
          <div class="flex gap-6 justify-center">
            <.link
              navigate={~p"/contact"}
              class="text-gray-400 hover:text-turquoise-400 transition-colors"
            >
              Contact
            </.link>
            <.link
              navigate={~p"/legal/privacy-policy"}
              class="text-gray-400 hover:text-turquoise-400 transition-colors"
            >
              Privacy Policy
            </.link>
            <.link
              navigate={~p"/legal/terms-and-conditions"}
              class="text-gray-400 hover:text-turquoise-400 transition-colors"
            >
              Terms of Service
            </.link>
          </div>
          <div class="mt-6 pt-4 border-t border-gray-700">
            <p class="text-gray-400 text-sm mb-2">Created with passion by</p>
            <a
              href="https://lukabreitig.com"
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-2 px-4 py-2 bg-gradient-to-r from-turquoise-500 to-turquoise-600 text-white font-semibold rounded-lg hover:from-turquoise-600 hover:to-turquoise-700 transform hover:scale-105 transition-all duration-200 shadow-lg hover:shadow-turquoise-500/25"
            >
              <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
                <path
                  fill-rule="evenodd"
                  d="M10 9a3 3 0 100-6 3 3 0 000 6zm-7 9a7 7 0 1114 0H3z"
                  clip-rule="evenodd"
                >
                </path>
              </svg>
              Luka Breitig
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
                >
                </path>
              </svg>
            </a>
          </div>
        </div>
      </div>
    </footer>
    """
  end

  # Private helper function to determine logo link destination
  @spec logo_link(map() | nil) :: String.t()
  defp logo_link(current_user) do
    cond do
      # If user is logged in, always go to dashboard
      current_user -> ~p"/dashboard"
      # If main deployment, go to homepage
      Deployment.main?() -> ~p"/"
      # If self-hosted, go to login
      true -> ~p"/auth/login"
    end
  end
end
