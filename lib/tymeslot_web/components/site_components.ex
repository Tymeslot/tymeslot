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
  alias Tymeslot.Infrastructure.Config
  import TymeslotWeb.Components.CoreComponents, only: [logo: 1]

  @doc """
  Main navigation component used across the application.
  """
  attr :current_user, :map, default: nil

  @spec navigation(map()) :: Phoenix.LiveView.Rendered.t()
  def navigation(assigns) do
    ~H"""
    <nav class="bg-white border-b-4 border-turquoise-500 shadow-xl relative z-50">
      <div class="container mx-auto flex justify-between items-center px-6 py-5">
        <%= if external_url?(logo_link(@current_user)) do %>
          <.link
            href={logo_link(@current_user)}
            class="flex items-center text-tymeslot-900 hover:text-turquoise-600 transition-all transform hover:scale-105"
          >
            <.logo mode={:full} img_class="h-12 shrink-0" />
          </.link>
        <% else %>
          <.link
            navigate={logo_link(@current_user)}
            class="flex items-center text-tymeslot-900 hover:text-turquoise-600 transition-all transform hover:scale-105"
          >
            <.logo mode={:full} img_class="h-12 shrink-0" />
          </.link>
        <% end %>
        
    <%!-- Desktop Navigation: marketing links (centre zone) --%>
        <div class="hidden md:flex flex-1 items-center justify-center gap-1">
          <%= if Config.show_marketing_links?() do %>
            <%= if features_url = Application.get_env(:tymeslot, :features_url) do %>
              <% feature_pages = Application.get_env(:tymeslot, :feature_pages, []) %>
              <%= if feature_pages == [] do %>
                <.nav_sublink
                  url={features_url}
                  class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
                >
                  Features
                </.nav_sublink>
              <% else %>
                <div class="relative group">
                  <.nav_sublink
                    url={features_url}
                    class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl inline-flex items-center gap-1.5"
                  >
                    Features
                    <svg
                      class="w-4 h-4 transition-transform duration-200 group-hover:rotate-180"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                      stroke-width="2.5"
                      aria-hidden="true"
                    >
                      <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
                    </svg>
                  </.nav_sublink>
                  <div class="invisible opacity-0 group-hover:visible group-hover:opacity-100 group-focus-within:visible group-focus-within:opacity-100 transition-all duration-200 absolute left-0 top-full pt-3 z-50">
                    <div class="w-72 bg-white rounded-2xl shadow-xl border border-tymeslot-100 p-2">
                      <.nav_sublink
                        url={features_url}
                        class="block px-4 py-2.5 rounded-xl text-tymeslot-700 hover:bg-turquoise-50 hover:text-turquoise-600 font-bold transition-colors"
                      >
                        All features
                      </.nav_sublink>
                      <div class="my-1 h-px bg-tymeslot-100" aria-hidden="true"></div>
                      <.nav_sublink
                        :for={page <- feature_pages}
                        url={page.url}
                        class="block px-4 py-2.5 rounded-xl text-tymeslot-700 hover:bg-turquoise-50 hover:text-turquoise-600 font-medium transition-colors"
                      >
                        {page.label}
                      </.nav_sublink>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
            <%= if pricing_url = Application.get_env(:tymeslot, :pricing_url) do %>
              <%= if external_url?(pricing_url) do %>
                <.link
                  href={pricing_url}
                  class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
                >
                  Pricing
                </.link>
              <% else %>
                <.link
                  navigate={pricing_url}
                  class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
                >
                  Pricing
                </.link>
              <% end %>
            <% end %>
            <%= if docs_url = Application.get_env(:tymeslot, :docs_url) do %>
              <%= if external_url?(docs_url) do %>
                <.link
                  href={docs_url}
                  class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
                >
                  Docs
                </.link>
              <% else %>
                <.link
                  navigate={docs_url}
                  class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
                >
                  Docs
                </.link>
              <% end %>
            <% end %>
            <%= if contact_url = Application.get_env(:tymeslot, :contact_url) do %>
              <%= if external_url?(contact_url) do %>
                <.link
                  href={contact_url}
                  class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
                >
                  Contact
                </.link>
              <% else %>
                <.link
                  navigate={contact_url}
                  class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
                >
                  Contact
                </.link>
              <% end %>
            <% end %>
          <% end %>
        </div>

    <%!-- Desktop Navigation: account actions (right zone) --%>
        <div class="hidden md:flex items-center gap-3">
          <%= if @current_user do %>
            <.link
              navigate={~p"/dashboard"}
              data-tymeslot-suppress-lv-disconnect
              class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
            >
              Dashboard
            </.link>
            <div class="h-6 w-px bg-tymeslot-200" aria-hidden="true"></div>
            <.link
              href={~p"/auth/logout"}
              method="delete"
              class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-red-600 hover:bg-red-50 transition-all rounded-2xl"
            >
              Logout
            </.link>
          <% else %>
            <.link
              href={~p"/auth/login"}
              class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
            >
              Login
            </.link>
            <div class="h-6 w-px bg-tymeslot-200" aria-hidden="true"></div>
            <.link
              href={~p"/auth/signup"}
              class="px-8 py-3 font-black text-white bg-linear-to-br from-turquoise-600 via-cyan-600 to-blue-600 hover:from-turquoise-500 hover:to-blue-500 rounded-2xl shadow-xl hover:shadow-turquoise-500/40 transition-all duration-300 hover:-translate-y-1"
            >
              Get Started
            </.link>
          <% end %>
        </div>
        
    <%!-- Mobile Menu Button --%>
        <button
          class="md:hidden mobile-menu-toggle flex items-center justify-center w-12 h-12 rounded-xl bg-turquoise-100 hover:bg-turquoise-200 transition-colors"
          phx-click={
            JS.toggle(to: "#mobile-menu")
            |> JS.toggle_class("mobile-menu-open", to: ".mobile-menu-toggle")
          }
          aria-label="Toggle menu"
        >
          <svg class="w-7 h-7 text-turquoise-700" fill="none" stroke="currentColor" viewBox="0 0 24 24" stroke-width="3">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M4 6h16M4 12h16M4 18h16"
            >
            </path>
          </svg>
        </button>
        
    <%!-- Mobile Menu --%>
        <div
          id="mobile-menu"
          class="mobile-menu md:hidden absolute top-full left-0 right-0 bg-white/95 backdrop-blur-md border-t border-tymeslot-200 shadow-lg hidden"
        >
          <div class="container mx-auto px-4 py-4 space-y-3">
            <%= if Config.show_marketing_links?() do %>
              <%= if features_url = Application.get_env(:tymeslot, :features_url) do %>
                <% feature_pages = Application.get_env(:tymeslot, :feature_pages, []) %>
                <.nav_sublink
                  url={features_url}
                  class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
                >
                  Features
                </.nav_sublink>
                <.nav_sublink
                  :for={page <- feature_pages}
                  url={page.url}
                  class="mobile-nav-link block px-4 py-2.5 pl-8 text-token-sm text-tymeslot-600 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
                >
                  {page.label}
                </.nav_sublink>
              <% end %>
              <%= if pricing_url = Application.get_env(:tymeslot, :pricing_url) do %>
                <%= if external_url?(pricing_url) do %>
                  <.link
                    href={pricing_url}
                    class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
                  >
                    Pricing
                  </.link>
                <% else %>
                  <.link
                    navigate={pricing_url}
                    class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
                  >
                    Pricing
                  </.link>
                <% end %>
              <% end %>
              <%= if docs_url = Application.get_env(:tymeslot, :docs_url) do %>
                <%= if external_url?(docs_url) do %>
                  <.link
                    href={docs_url}
                    class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
                  >
                    Docs
                  </.link>
                <% else %>
                  <.link
                    navigate={docs_url}
                    class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
                  >
                    Docs
                  </.link>
                <% end %>
              <% end %>
              <%= if contact_url = Application.get_env(:tymeslot, :contact_url) do %>
                <%= if external_url?(contact_url) do %>
                  <.link
                    href={contact_url}
                    class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
                  >
                    Contact
                  </.link>
                <% else %>
                  <.link
                    navigate={contact_url}
                    class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
                  >
                    Contact
                  </.link>
                <% end %>
              <% end %>
            <% end %>
            <%= if @current_user do %>
              <.link
                navigate={~p"/dashboard"}
                data-tymeslot-suppress-lv-disconnect
                class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
              >
                Dashboard
              </.link>
              <.link
                href={~p"/auth/logout"}
                method="delete"
                class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
              >
                Logout
              </.link>
            <% else %>
              <.link
                href={~p"/auth/login"}
                class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
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

  ## Slots

    * `supplemental_nav` — optional extra link columns rendered alongside the built-in
      Product and Legal columns. Each slot entry should contain a heading and a list of
      links that match the built-in column style (see the module doc for class conventions).

  """
  slot :supplemental_nav, required: false do
    attr :class, :string, doc: "Extra CSS classes on the wrapper div (e.g. col-span-2)."
  end

  @spec site_footer(map()) :: Phoenix.LiveView.Rendered.t()
  def site_footer(assigns) do
    ~H"""
    <footer class="mt-auto bg-linear-to-r from-tymeslot-900 to-tymeslot-800">
      <div class="container mx-auto px-6 py-16 max-w-7xl">
        <div class="flex flex-col lg:flex-row gap-12 mb-12">
          <%!-- Brand column --%>
          <div class="lg:w-72 shrink-0">
            <.link href={~p"/"} class="inline-block mb-5">
              <.logo mode={:full} img_class="h-10" />
            </.link>
            <p class="text-tymeslot-400 text-token-sm leading-relaxed mb-6 max-w-xs">
              Privacy-first meeting scheduling. No ads, no tracking. Just booking.
            </p>
            <a
              href="https://lukabreitig.com"
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-2 px-4 py-2 bg-linear-to-r from-turquoise-500 to-turquoise-600 text-white font-semibold rounded-token-lg hover:from-turquoise-600 hover:to-turquoise-700 hover:scale-105 transition-all duration-200 shadow-lg hover:shadow-turquoise-500/25 text-token-sm"
            >
              <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                <path
                  fill-rule="evenodd"
                  d="M10 9a3 3 0 100-6 3 3 0 000 6zm-7 9a7 7 0 1114 0H3z"
                  clip-rule="evenodd"
                >
                </path>
              </svg>
              Luka Breitig
              <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
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

          <%!-- Link columns --%>
          <div class="flex-1 grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-8">
            <%!-- Product column --%>
            <%= if Config.show_marketing_links?() do %>
              <div>
                <h4 class="text-white font-bold text-token-sm mb-4 uppercase tracking-widest">
                  Product
                </h4>
                <ul class="space-y-3">
                  <%= if url = Application.get_env(:tymeslot, :features_url) do %>
                    <li>
                      <%= if external_url?(url) do %>
                        <.link
                          href={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Features
                        </.link>
                      <% else %>
                        <.link
                          navigate={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Features
                        </.link>
                      <% end %>
                    </li>
                  <% end %>
                  <%= if url = Application.get_env(:tymeslot, :pricing_url) do %>
                    <li>
                      <%= if external_url?(url) do %>
                        <.link
                          href={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Pricing
                        </.link>
                      <% else %>
                        <.link
                          navigate={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Pricing
                        </.link>
                      <% end %>
                    </li>
                  <% end %>
                  <%= if url = Application.get_env(:tymeslot, :docs_url) do %>
                    <li>
                      <%= if external_url?(url) do %>
                        <.link
                          href={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Docs
                        </.link>
                      <% else %>
                        <.link
                          navigate={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Docs
                        </.link>
                      <% end %>
                    </li>
                  <% end %>
                  <%= if url = Application.get_env(:tymeslot, :changelog_url) do %>
                    <li>
                      <%= if external_url?(url) do %>
                        <.link
                          href={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Changelog
                        </.link>
                      <% else %>
                        <.link
                          navigate={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Changelog
                        </.link>
                      <% end %>
                    </li>
                  <% end %>
                  <%= if url = Application.get_env(:tymeslot, :contact_url) do %>
                    <li>
                      <%= if external_url?(url) do %>
                        <.link
                          href={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Contact
                        </.link>
                      <% else %>
                        <.link
                          navigate={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Contact
                        </.link>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              </div>

              <%!-- Legal column --%>
              <div>
                <h4 class="text-white font-bold text-token-sm mb-4 uppercase tracking-widest">
                  Legal
                </h4>
                <ul class="space-y-3">
                  <%= if url = Application.get_env(:tymeslot, :privacy_policy_url) do %>
                    <li>
                      <%= if external_url?(url) do %>
                        <.link
                          href={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Privacy Policy
                        </.link>
                      <% else %>
                        <.link
                          navigate={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Privacy Policy
                        </.link>
                      <% end %>
                    </li>
                  <% end %>
                  <%= if url = Application.get_env(:tymeslot, :terms_and_conditions_url) do %>
                    <li>
                      <%= if external_url?(url) do %>
                        <.link
                          href={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Terms and Conditions
                        </.link>
                      <% else %>
                        <.link
                          navigate={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Terms and Conditions
                        </.link>
                      <% end %>
                    </li>
                  <% end %>
                  <%= if url = Application.get_env(:tymeslot, :sitemap_url) do %>
                    <li>
                      <%= if external_url?(url) do %>
                        <.link
                          href={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Sitemap
                        </.link>
                      <% else %>
                        <.link
                          navigate={url}
                          class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
                        >
                          Sitemap
                        </.link>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>

            <%!-- Supplemental nav columns injected by consumers (e.g. SaaS use cases) --%>
            <div :for={col <- @supplemental_nav} class={col[:class]}>
              {render_slot(col)}
            </div>
          </div>
        </div>

        <%!-- Bottom bar --%>
        <div class="border-t border-tymeslot-700 pt-6 flex flex-col sm:flex-row justify-between items-center gap-3">
          <p class="text-tymeslot-500 text-token-xs">
            © {DateTime.utc_now().year} Tymeslot. All rights reserved. · v{to_string(Application.spec(:tymeslot, :vsn))}
          </p>
        </div>
      </div>
    </footer>
    """
  end

  # Renders a navigation link, choosing `href` for external URLs and `navigate`
  # for internal ones. Keeps the external/internal branch out of the markup so
  # the dropdown and mobile sub-links stay readable.
  attr :url, :string, required: true
  attr :class, :string, required: true
  slot :inner_block, required: true

  defp nav_sublink(assigns) do
    ~H"""
    <.link :if={external_url?(@url)} href={@url} class={@class}>{render_slot(@inner_block)}</.link>
    <.link :if={not external_url?(@url)} navigate={@url} class={@class}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # Private helper function to determine logo link destination
  @spec logo_link(map() | nil) :: String.t()
  defp logo_link(current_user) do
    cond do
      # If user is logged in, always go to dashboard
      current_user ->
        ~p"/dashboard"

      # If logo should link to marketing, go to the site home path
      Config.logo_links_to_marketing?() ->
        Config.site_home_path()

      # If standalone, go to login
      true ->
        ~p"/auth/login"
    end
  end

  @spec external_url?(String.t() | nil) :: boolean()
  defp external_url?(nil), do: false
  defp external_url?(url), do: String.starts_with?(url, ["http://", "https://"])
end
