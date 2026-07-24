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
  import TymeslotWeb.Components.CoreComponents, only: [logo: 1, icon: 1]

  @doc """
  Main navigation component used across the application.
  """
  attr :current_user, :map, default: nil

  @spec navigation(map()) :: Phoenix.LiveView.Rendered.t()
  def navigation(assigns) do
    ~H"""
    <% menu_sections = nav_menu_sections() %>
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
        <div class="hidden lg:flex flex-1 items-center justify-center gap-1">
          <%= if Config.show_marketing_links?() do %>
            <.nav_section :for={section <- menu_sections} section={section} />
          <% end %>
        </div>

    <%!-- Desktop Navigation: account actions (right zone) --%>
        <div class="hidden lg:flex items-center gap-3">
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
              data-analytics-event="signup_started"
              data-analytics-props={Jason.encode!(%{source_page: "marketing", cta_location: "nav"})}
              class="px-8 py-3 font-black text-white bg-linear-to-br from-turquoise-600 via-cyan-600 to-blue-600 hover:from-turquoise-500 hover:to-blue-500 rounded-2xl shadow-xl hover:shadow-turquoise-500/40 transition-all duration-300 hover:-translate-y-1"
            >
              Get Started
            </.link>
          <% end %>
        </div>

    <%!-- Mobile Menu Button --%>
        <button
          class="lg:hidden mobile-menu-toggle flex items-center justify-center w-12 h-12 rounded-xl bg-turquoise-100 hover:bg-turquoise-200 transition-colors"
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
          class="mobile-menu lg:hidden absolute top-full left-0 right-0 bg-white/95 backdrop-blur-md border-t border-tymeslot-200 shadow-lg hidden"
        >
          <div class="container mx-auto px-4 py-4 space-y-3">
            <%= if Config.show_marketing_links?() do %>
              <.nav_section_mobile :for={section <- menu_sections} section={section} />
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
                data-analytics-event="signup_started"
                data-analytics-props={
                  Jason.encode!(%{source_page: "marketing", cta_location: "mobile_menu"})
                }
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

  # Single source of truth for the top-level marketing navigation. Both the
  # desktop and mobile menus iterate this list, so a new entry appears in both
  # without being wired up twice. Each entry is either:
  #
  #   * `%{kind: :menu, ...}` — a grouped menu rendered as a desktop hover
  #     dropdown / mobile accordion. Carries an optional landing `url`, an
  #     optional `overview` row (a highlighted link to that landing page), and
  #     the `pages` it groups. A `:menu` with no `pages` collapses to a plain
  #     link to its `url`.
  #   * `%{kind: :link, ...}` — a flat top-level link (Pricing, Docs, Contact).
  @spec nav_menu_sections() :: [map()]
  defp nav_menu_sections do
    features_url = Application.get_env(:tymeslot, :features_url)
    feature_pages = Application.get_env(:tymeslot, :feature_pages, [])
    resources_pages = Application.get_env(:tymeslot, :resources_pages, [])

    marketing_links =
      Enum.filter(
        [
          %{
            kind: :link,
            url: Application.get_env(:tymeslot, :pricing_url),
            label: "Pricing",
            icon: "hero-tag"
          },
          %{
            kind: :link,
            url: Application.get_env(:tymeslot, :docs_url),
            label: "Docs",
            icon: "hero-book-open"
          },
          %{
            kind: :link,
            url: Application.get_env(:tymeslot, :contact_url),
            label: "Contact",
            icon: "hero-envelope"
          }
        ],
        & &1.url
      )

    feature_section =
      features_url &&
        %{
          kind: :menu,
          label: "Features",
          icon: "hero-sparkles",
          url: features_url,
          overview: %{label: "All features", icon: "hero-squares-2x2-solid", url: features_url},
          pages: feature_pages
        }

    resources_section =
      resources_pages != [] &&
        %{
          kind: :menu,
          label: "Resources",
          icon: "hero-rectangle-stack",
          url: nil,
          overview: nil,
          pages: resources_pages
        }

    Enum.filter([feature_section, resources_section | marketing_links], & &1)
  end

  # Desktop navigation entry. A `:link` renders as a flat top-level link; a
  # `:menu` with no sub-pages collapses to a plain link to its landing page;
  # otherwise it renders a hover dropdown grouping the section's pages.
  attr :section, :map, required: true

  defp nav_section(%{section: %{kind: :link}} = assigns) do
    ~H"""
    <.nav_sublink
      url={@section.url}
      class="group px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl inline-flex items-center gap-2"
    >
      <.icon
        name={@section.icon}
        class="w-4 h-4 shrink-0 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors"
      /> {@section.label}
    </.nav_sublink>
    """
  end

  defp nav_section(%{section: %{kind: :menu, pages: []}} = assigns) do
    ~H"""
    <.nav_sublink
      url={@section.url}
      class="group px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl inline-flex items-center gap-2"
    >
      <.icon
        name={@section.icon}
        class="w-4 h-4 shrink-0 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors"
      /> {@section.label}
    </.nav_sublink>
    """
  end

  defp nav_section(%{section: %{kind: :menu}} = assigns) do
    ~H"""
    <div class="relative group">
      <%!-- Trigger: a link when the menu has a landing page, a disclosure button otherwise. --%>
      <.nav_sublink
        :if={@section.url}
        url={@section.url}
        class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl inline-flex items-center gap-2"
      >
        <.icon
          name={@section.icon}
          class="w-4 h-4 shrink-0 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors"
        /> {@section.label}
        <.nav_chevron />
      </.nav_sublink>
      <button
        :if={!@section.url}
        type="button"
        class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl inline-flex items-center gap-2"
        aria-haspopup="true"
      >
        <.icon
          name={@section.icon}
          class="w-4 h-4 shrink-0 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors"
        /> {@section.label}
        <.nav_chevron />
      </button>
      <div class="invisible opacity-0 group-hover:visible group-hover:opacity-100 group-focus-within:visible group-focus-within:opacity-100 transition-all duration-200 absolute left-0 top-full pt-3 z-50">
        <div class={[
          "bg-white rounded-2xl shadow-xl border border-tymeslot-100 p-2",
          if(@section.overview, do: "w-80", else: "w-72")
        ]}>
          <.nav_sublink
            :if={@section.overview}
            url={@section.overview.url}
            class="group/feat flex items-center gap-3 px-3 py-2.5 rounded-xl text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-700 font-bold transition-colors"
          >
            <.nav_icon_tile name={@section.overview.icon} variant={:solid} /> {@section.overview.label}
          </.nav_sublink>
          <div :if={@section.overview} class="my-1 h-px bg-tymeslot-100" aria-hidden="true"></div>
          <.nav_sublink
            :for={page <- @section.pages}
            url={page.url}
            class="group/feat flex items-center gap-3 px-3 py-2.5 rounded-xl text-tymeslot-700 hover:bg-turquoise-50 hover:text-turquoise-700 font-medium transition-colors"
          >
            <.nav_icon_tile :if={page[:icon]} name={page.icon} />
            {page.label}
          </.nav_sublink>
        </div>
      </div>
    </div>
    """
  end

  # Mobile navigation entry. Mirrors `nav_section` for the same data: a flat
  # link, a collapsed plain link, or — for a populated `:menu` — a tappable
  # accordion that toggles its grouped sub-pages.
  attr :section, :map, required: true

  defp nav_section_mobile(%{section: %{kind: :link}} = assigns) do
    ~H"""
    <.nav_sublink
      url={@section.url}
      class="group mobile-nav-link flex items-center gap-2.5 px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
    >
      <.icon
        name={@section.icon}
        class="w-5 h-5 shrink-0 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors"
      /> {@section.label}
    </.nav_sublink>
    """
  end

  defp nav_section_mobile(%{section: %{kind: :menu, pages: []}} = assigns) do
    ~H"""
    <.nav_sublink
      url={@section.url}
      class="group mobile-nav-link flex items-center gap-2.5 px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
    >
      <.icon
        name={@section.icon}
        class="w-5 h-5 shrink-0 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors"
      /> {@section.label}
    </.nav_sublink>
    """
  end

  defp nav_section_mobile(%{section: %{kind: :menu}} = assigns) do
    assigns = assign(assigns, :panel_id, "mobile-nav-#{nav_slug(assigns.section.label)}")

    ~H"""
    <div>
      <button
        type="button"
        class="group/acc w-full mobile-nav-link flex items-center gap-2.5 px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
        aria-controls={@panel_id}
        phx-click={
          JS.toggle(to: "##{@panel_id}")
          |> JS.toggle_class("rotate-180", to: "##{@panel_id}-chevron")
        }
      >
        <.icon
          name={@section.icon}
          class="w-5 h-5 shrink-0 text-tymeslot-400 group-hover/acc:text-turquoise-600 transition-colors"
        />
        <span class="flex-1 text-left">{@section.label}</span>
        <.nav_chevron id={"#{@panel_id}-chevron"} />
      </button>
      <div id={@panel_id} class="hidden pl-2 space-y-1">
        <.nav_sublink
          :if={@section.overview}
          url={@section.overview.url}
          class="group/feat mobile-nav-link flex items-center gap-3 px-4 py-2.5 text-tymeslot-700 hover:bg-turquoise-50 hover:text-turquoise-700 font-bold rounded-lg transition-colors"
        >
          <.nav_icon_tile name={@section.overview.icon} variant={:solid} class="w-8 h-8" icon_class="w-4 h-4" />
          {@section.overview.label}
        </.nav_sublink>
        <.nav_sublink
          :for={page <- @section.pages}
          url={page.url}
          class="group/feat mobile-nav-link flex items-center gap-3 px-4 py-2.5 text-token-sm text-tymeslot-600 hover:bg-turquoise-50 hover:text-turquoise-700 rounded-lg transition-colors"
        >
          <.nav_icon_tile :if={page[:icon]} name={page.icon} class="w-8 h-8" icon_class="w-4 h-4" />
          {page.label}
        </.nav_sublink>
      </div>
    </div>
    """
  end

  # Downward chevron used by menu triggers. Rotates 180° on desktop hover; the
  # mobile accordion toggles the rotation via an explicit `id` and `JS`.
  attr :id, :string, default: nil

  defp nav_chevron(assigns) do
    ~H"""
    <svg
      id={@id}
      class={[
        "w-4 h-4 transition-transform duration-200",
        is_nil(@id) && "group-hover:rotate-180"
      ]}
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      stroke-width="2.5"
      aria-hidden="true"
    >
      <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
    </svg>
    """
  end

  # Turns a menu label into a DOM-id-safe slug for the mobile accordion panel.
  @spec nav_slug(String.t()) :: String.t()
  defp nav_slug(label) do
    label |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
  end

  # Brand "icon tile" for the Features navigation dropdown. `:soft` (default)
  # sits as a tinted tile that inverts to the turquoise→cyan gradient when the
  # enclosing `group/feat` row is hovered; `:solid` always shows the gradient,
  # used to emphasise the "All features" overview row.
  attr :name, :string, required: true
  attr :class, :string, default: "w-9 h-9"
  attr :icon_class, :string, default: "w-5 h-5"
  attr :variant, :atom, values: [:soft, :solid], default: :soft

  defp nav_icon_tile(assigns) do
    ~H"""
    <span class={[
      "flex items-center justify-center rounded-lg shrink-0 transition-all",
      @class,
      @variant == :soft &&
        "bg-turquoise-50 text-turquoise-600 group-hover/feat:bg-linear-to-br group-hover/feat:from-turquoise-500 group-hover/feat:to-cyan-500 group-hover/feat:text-white",
      @variant == :solid && "bg-linear-to-br from-turquoise-500 to-cyan-500 text-white shadow-sm"
    ]}>
      <.icon name={@name} class={@icon_class} />
    </span>
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
    <% product_links =
      footer_links([
        {:features_url, "Features"},
        {:pricing_url, "Pricing"},
        {:enterprise_url, "Enterprise"},
        {:docs_url, "Docs"},
        {:changelog_url, "Changelog"},
        {:about_url, "About"},
        {:contact_url, "Contact"}
      ]) %>
    <% legal_links =
      footer_links([
        {:privacy_policy_url, "Privacy Policy"},
        {:terms_and_conditions_url, "Terms and Conditions"},
        {:sitemap_url, "Sitemap"}
      ]) %>
    <footer class="mt-auto bg-linear-to-r from-tymeslot-900 to-tymeslot-800">
      <div class="container mx-auto px-6 py-16 max-w-7xl">
        <div class="flex flex-col lg:flex-row gap-12 mb-12">
          <%!-- Brand column --%>
          <div class="lg:w-72 shrink-0">
            <.link href={~p"/"} class="inline-block mb-5">
              <.logo mode={:full} img_class="h-10" />
            </.link>
            <p class="text-tymeslot-400 text-token-sm leading-relaxed mb-6 max-w-xs">
              Beautiful, on-brand meeting scheduling. No ads, no tracking.
            </p>
            <a
              href="https://github.com/tymeslot/tymeslot"
              target="_blank"
              rel="noopener noreferrer"
              data-analytics-event="github_cta_clicked"
              data-analytics-props={Jason.encode!(%{source_page: "footer"})}
              class="inline-flex items-center gap-2 px-4 py-2 bg-linear-to-r from-turquoise-500 to-turquoise-600 text-white font-semibold rounded-token-lg hover:from-turquoise-600 hover:to-turquoise-700 hover:scale-105 transition-all duration-200 shadow-lg hover:shadow-turquoise-500/25 text-token-sm"
            >
              <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24" aria-hidden="true">
                <path
                  fill-rule="evenodd"
                  clip-rule="evenodd"
                  d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.02 10.02 0 0022 12.017C22 6.484 17.522 2 12 2z"
                >
                </path>
              </svg>
              View on GitHub
            </a>
          </div>

          <%!-- Link columns --%>
          <div class="flex-1 grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-8">
            <%= if Config.show_marketing_links?() do %>
              <.footer_column heading="Product" links={product_links} />
              <.footer_column heading="Legal" links={legal_links} />
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

  # A single footer link column: a heading above a list of internal/external links.
  attr :heading, :string, required: true
  attr :links, :list, required: true

  defp footer_column(assigns) do
    ~H"""
    <div>
      <%!-- h3, not h4: the last heading before the footer on every page is an
           h2, so an h4 here skips a level and fails the heading-order check. --%>
      <h3 class="text-white font-bold text-token-sm mb-4 uppercase tracking-widest">
        {@heading}
      </h3>
      <ul class="space-y-3">
        <li :for={link <- @links}>
          <.nav_sublink
            url={link.url}
            class="text-tymeslot-400 hover:text-turquoise-400 transition-colors text-token-sm"
          >
            {link.label}
          </.nav_sublink>
        </li>
      </ul>
    </div>
    """
  end

  # Resolves a list of `{config_key, label}` pairs into `%{url, label}` entries,
  # dropping any whose URL is not configured.
  @spec footer_links([{atom(), String.t()}]) :: [%{url: String.t(), label: String.t()}]
  defp footer_links(specs) do
    specs
    |> Enum.map(fn {key, label} -> %{url: Application.get_env(:tymeslot, key), label: label} end)
    |> Enum.filter(& &1.url)
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
