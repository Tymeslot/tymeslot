defmodule TymeslotWeb.Components.SiteComponents do
  @moduledoc """
  Site-wide components for navigation, footer, and other shared UI elements.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

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

  ## Marketing menu

  The centre-zone marketing menu is caller-supplied via `menu_sections`, not
  built here — the menu labels are a SaaS marketing concern and live in SaaS's
  `marketing_*` gettext catalogues, resolved per request. Core standalone passes
  nothing, so the default `[]` renders no marketing links. Each entry is either:

    * `%{kind: :link, url:, label:, icon:}` — a flat top-level link.
    * `%{kind: :menu, key:, label:, icon:, url:, overview:, pages:}` — a grouped
      menu rendered as a desktop hover dropdown / mobile accordion. `key` is a
      stable, translation-independent slug used for the mobile accordion's DOM
      id (the label can't be — a translated label may slug to nothing). `url`
      is an optional landing page, `overview` an optional highlighted row
      (`%{label:, icon:, url:}` or `nil`), and `pages` the grouped
      `%{label:, url:, icon:}` entries. A `:menu` with no `pages` collapses to a
      plain link to its `url`.

  ## Slots

    * `end_actions` — optional controls rendered in the desktop right-hand action
      zone, before the account actions (Login / Get Started). Used by consumers
      that need a compact top-level control such as a language switcher.
    * `mobile_actions` — the mobile counterpart, rendered inside the mobile menu
      after the marketing links.

  Both slots are optional; Core standalone renders neither.
  """
  attr :current_user, :map, default: nil
  attr :menu_sections, :list, default: []
  slot :end_actions, required: false
  slot :mobile_actions, required: false

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
        <div class="hidden lg:flex flex-1 items-center justify-center gap-1">
          <.nav_section :for={section <- @menu_sections} section={section} />
        </div>

        <%!-- Desktop Navigation: account actions (right zone) --%>
        <div class="hidden lg:flex items-center gap-3">
          {render_slot(@end_actions)}
          <%= if @current_user do %>
            <.link
              navigate={~p"/dashboard"}
              data-tymeslot-suppress-lv-disconnect
              class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
            >
              {dgettext("common", "Dashboard")}
            </.link>
            <div class="h-6 w-px bg-tymeslot-200" aria-hidden="true"></div>
            <.link
              href={~p"/auth/logout"}
              method="delete"
              class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-red-600 hover:bg-red-50 transition-all rounded-2xl"
            >
              {dgettext("common", "Logout")}
            </.link>
          <% else %>
            <.link
              href={~p"/auth/login"}
              class="px-4 py-2 font-semibold text-tymeslot-700 hover:text-turquoise-600 hover:bg-turquoise-50 transition-all rounded-2xl"
            >
              {dgettext("common", "Login")}
            </.link>
            <div class="h-6 w-px bg-tymeslot-200" aria-hidden="true"></div>
            <.link
              href={~p"/auth/signup"}
              data-analytics-event="signup_started"
              data-analytics-props={Jason.encode!(%{source_page: "marketing", cta_location: "nav"})}
              class="px-8 py-3 font-black text-white bg-linear-to-br from-turquoise-600 via-cyan-600 to-blue-600 hover:from-turquoise-500 hover:to-blue-500 rounded-2xl shadow-xl hover:shadow-turquoise-500/40 transition-all duration-300 hover:-translate-y-1"
            >
              {dgettext("common", "Get Started")}
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
          aria-label={dgettext("common", "Toggle menu")}
        >
          <svg
            class="w-7 h-7 text-turquoise-700"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            stroke-width="3"
          >
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
            <.nav_section_mobile :for={section <- @menu_sections} section={section} />
            {render_slot(@mobile_actions)}
            <%= if @current_user do %>
              <.link
                navigate={~p"/dashboard"}
                data-tymeslot-suppress-lv-disconnect
                class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
              >
                {dgettext("common", "Dashboard")}
              </.link>
              <.link
                href={~p"/auth/logout"}
                method="delete"
                class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
              >
                {dgettext("common", "Logout")}
              </.link>
            <% else %>
              <.link
                href={~p"/auth/login"}
                class="mobile-nav-link block px-4 py-3 text-tymeslot-800 hover:bg-turquoise-50 hover:text-turquoise-600 rounded-lg transition-colors"
              >
                {dgettext("common", "Login")}
              </.link>
              <.link
                href={~p"/auth/signup"}
                data-analytics-event="signup_started"
                data-analytics-props={
                  Jason.encode!(%{source_page: "marketing", cta_location: "mobile_menu"})
                }
                class="mobile-nav-button block px-4 py-3 bg-turquoise-600 text-white text-center rounded-lg hover:bg-turquoise-700 transition-colors"
              >
                {dgettext("common", "Get Started")}
              </.link>
            <% end %>
          </div>
        </div>
      </div>
    </nav>
    """
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
    assigns = assign(assigns, :panel_id, "mobile-nav-#{assigns.section.key}")

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
          <.nav_icon_tile
            name={@section.overview.icon}
            variant={:solid}
            class="w-8 h-8"
            icon_class="w-4 h-4"
          />
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
  Site footer component.

  ## Attributes

    * `link_columns` — caller-supplied link columns rendered beside the brand
      column, each `%{heading: string, links: [%{url:, label:}]}`. The marketing
      link labels are a caller concern (they live in the caller's gettext
      catalogues), so Core does not build them here. Core standalone passes none,
      leaving just the brand column and copyright.
  """
  attr :link_columns, :list, default: []

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
              {dgettext("common", "Beautiful, on-brand meeting scheduling. No ads, no tracking.")}
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
              {dgettext("common", "View on GitHub")}
            </a>
          </div>

          <%!-- Link columns — caller-supplied so the (marketing) labels stay out of Core --%>
          <div class="flex-1 grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-8">
            <.footer_column :for={col <- @link_columns} heading={col.heading} links={col.links} />
          </div>
        </div>

        <%!-- Bottom bar --%>
        <div class="border-t border-tymeslot-700 pt-6 flex flex-col sm:flex-row justify-between items-center gap-3">
          <p class="text-tymeslot-500 text-token-xs">
            {dgettext("common", "© %{year} Tymeslot. All rights reserved.",
              year: DateTime.utc_now().year
            )} · v{to_string(Application.spec(:tymeslot, :vsn))}
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
