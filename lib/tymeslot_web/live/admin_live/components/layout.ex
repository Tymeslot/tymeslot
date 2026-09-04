defmodule TymeslotWeb.AdminLive.Components.Layout do
  @moduledoc """
  Page chrome for the admin section — top nav with Back-to-Dashboard and
  the user dropdown, plus the section header and pill-style tab bar.

  Mirrors `AccountLive` so admin feels like part of the dashboard chrome.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.AdminLive.Tabs
  alias TymeslotWeb.Components.UserDropdownComponent

  attr :live_action, :atom, required: true
  attr :current_user, :map, required: true
  attr :profile, :any, required: true
  slot :inner_block, required: true

  @spec admin_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def admin_layout(assigns) do
    ~H"""
    <div class="min-h-screen">
      <%!-- Top nav: mirrors AccountLive so admin feels part of the dashboard chrome --%>
      <nav class="brand-nav mb-6 relative">
        <div class="container mx-auto px-4">
          <div class="flex items-center justify-between h-16">
            <.link
              patch={~p"/dashboard"}
              class="inline-flex items-center space-x-2 btn-secondary text-sm px-4 py-2"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" />
              <span>{dgettext("dashboard_admin", "Back to Dashboard")}</span>
            </.link>

            <div class="relative">
              <.live_component
                module={UserDropdownComponent}
                id="user-dropdown"
                current_user={@current_user}
                profile={@profile}
              />
            </div>
          </div>
        </div>
      </nav>

      <div class="container mx-auto px-4 py-8">
        <main>
          <div class="max-w-6xl mx-auto">
            <.section_header icon="hero-cog-6-tooth" title={dgettext("dashboard_admin", "Admin")} />
            <p class="mb-8 -mt-2 text-base text-tymeslot-600 font-medium">
              {dgettext("dashboard_admin", "Manage this self-hosted Tymeslot install.")}
            </p>

            <%!-- Pill-style tab bar. Wraps rather than overflowing: the tab
                 list grows with the settings, and a bar that scrolls
                 sideways hides tabs on exactly the narrow screens where
                 they are hardest to find. --%>
            <nav
              class="mb-8 inline-flex flex-wrap p-1 bg-white border-2 border-tymeslot-100 rounded-token-2xl shadow-sm gap-1"
              aria-label={dgettext("dashboard_admin", "Admin sections")}
            >
              <.tab_link
                :for={tab <- Tabs.all()}
                to={tab_path(tab)}
                active={@live_action == tab}
              >
                {Tabs.name(tab)}
              </.tab_link>
            </nav>

            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>
    """
  end

  # Verified routes need a literal path, so each tab names its own rather than
  # being interpolated into ~p.
  defp tab_path(:authentication), do: ~p"/admin/authentication"
  defp tab_path(:email), do: ~p"/admin/email"
  defp tab_path(:general), do: ~p"/admin/general"
  defp tab_path(:users), do: ~p"/admin/users"

  attr :to, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "px-4 py-2 rounded-token-xl text-sm font-bold transition-colors",
        if(@active,
          do: "bg-turquoise-600 text-white shadow-md shadow-turquoise-200/40",
          else: "text-tymeslot-600 hover:bg-tymeslot-50 hover:text-tymeslot-900"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
