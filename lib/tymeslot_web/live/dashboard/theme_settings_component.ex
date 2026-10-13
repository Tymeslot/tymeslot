defmodule TymeslotWeb.Dashboard.ThemeSettingsComponent do
  @moduledoc """
  Theme selection component for the dashboard.
  Allows users to select their booking page theme.

  Everything here applies to the page chosen by the `page` query parameter
  (`/dashboard/theme?page=<id>`), or to the profile's own page at
  `/<username>` without one. A booking page is edited through the owner's
  profile as that page presents it (`BookingPages.apply_to_profile/2`, held in
  `@page_profile`), so the theme cards, booking texts and colour editor read
  the page's values unchanged; only the writes branch on whether a page is
  selected.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.BookingPages
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias TymeslotWeb.Dashboard.ThemeSettings.BookingTextForm
  alias TymeslotWeb.Dashboard.ThemeSettings.PagesComponent
  alias TymeslotWeb.Dashboard.ThemeSettings.PageSettingsComponent
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationComponent
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemePreview
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    customization_theme_id =
      if assigns.live_action == :theme_customization do
        theme_id = assigns.params["theme_id"]
        if ThemeInfo.valid_theme_id?(theme_id), do: theme_id, else: nil
      else
        assigns[:customization_theme_id]
      end

    show_customization =
      (assigns.live_action == :theme_customization && not is_nil(customization_theme_id)) ||
        assigns[:show_customization] || false

    pages = BookingPages.list(assigns.profile.id)
    selected_page = Enum.find(pages, &(to_string(&1.id) == assigns[:params]["page"]))

    socket =
      socket
      |> assign(assigns)
      |> assign(:themes, ThemeInfo.theme_options())
      |> assign(:show_customization, show_customization)
      |> assign(:customization_theme_id, customization_theme_id)
      |> assign(:pages, pages)
      |> assign(:selected_page, selected_page)
      |> assign(:page_profile, page_profile(assigns.profile, selected_page))
      |> assign_new(:customization_timestamp, fn -> System.system_time() end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <.dashboard_page icon="hero-paint-brush" title={dgettext("dashboard_common", "Theme")}>
        <%= if @show_customization && @customization_theme_id do %>
          <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
            <p :if={@pages != []} class="mb-6 text-token-sm font-semibold text-tymeslot-600">
              {dgettext("dashboard_appearance", "You are editing %{address}",
                address: "/" <> (BookingPages.public_address(@page_profile) || "")
              )}
            </p>
            <.live_component
              module={ThemeCustomizationComponent}
              id={
                "theme-customization-#{@customization_theme_id}-#{@customization_timestamp}" <>
                  page_suffix(@selected_page)
              }
              profile={@page_profile}
              theme_id={@customization_theme_id}
              parent_component={@myself}
            />
          </div>
        <% else %>
          <.live_component
            module={PagesComponent}
            id="booking-pages"
            profile={@profile}
            pages={@pages}
            selected_page={@selected_page}
          />

          <div class="mb-16 max-w-2xl">
            <p class="text-xl text-tymeslot-500 font-medium leading-relaxed">
              {dgettext(
                "dashboard_appearance",
                "Select the interface that best represents your personal brand and creates the best experience for your clients."
              )}
            </p>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-10">
            <%= for {theme_name, theme_id} <- @themes do %>
              <div class="group/theme space-y-6">
                <.card
                  padding={:none}
                  interactive
                  class={[
                    "overflow-hidden duration-500",
                    if(@page_profile.booking_theme == theme_id,
                      do:
                        "glass-gradient border-turquoise-400 shadow-turquoise-500/20 ring-4 ring-turquoise-50",
                      else: "hover:border-turquoise-200 hover:shadow-tymeslot-200/50"
                    )
                  ]}
                  phx-click="select_theme"
                  phx-value-theme={theme_id}
                  phx-target={@myself}
                >
                  <div class="h-64 relative overflow-hidden">
                    <ThemePreview.render theme_id={theme_id} />

                    <div class="absolute inset-0 bg-linear-to-t from-tymeslot-900/60 via-transparent to-transparent opacity-60 group-hover/theme:opacity-40 transition-opacity">
                    </div>

                    <div class="absolute bottom-6 left-6 right-6 flex items-center justify-between">
                      <h2 class="text-token-lg font-semibold text-white drop-shadow-md">
                        {theme_name}
                      </h2>
                      <%= if @page_profile.booking_theme == theme_id do %>
                        <.pill tone={:brand} size={:sm} icon="hero-check">
                          {dgettext("dashboard_appearance", "Current style")}
                        </.pill>
                      <% end %>
                    </div>

                    <div
                      :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
                      class="absolute inset-0 bg-tymeslot-900/40 backdrop-blur-[2px] flex flex-col items-center justify-center cursor-not-allowed z-20"
                    >
                      <div class="w-12 h-12 bg-white/20 rounded-token-2xl flex items-center justify-center mb-3">
                        <.icon name="hero-lock-closed" class="w-6 h-6 text-white" />
                      </div>
                      <span class="text-white font-black text-token-xs uppercase tracking-widest">
                        {dgettext("dashboard_appearance", "Connect Calendar to Preview")}
                      </span>
                    </div>
                  </div>

                  <div class="p-8">
                    <p class="text-tymeslot-600 font-medium leading-relaxed line-clamp-2">
                      {ThemeInfo.get_description(theme_id)}
                    </p>
                  </div>
                </.card>

                <%!-- Wraps rather than overflows when a narrow card cannot fit both
                    labels on one line. --%>
                <div class="flex flex-wrap gap-4">
                  <%= if LinkAccessPolicy.can_link?(@profile, @integration_status) do %>
                    <.action_link
                      href={
                        PreviewMode.owner_path(
                          BookingPages.public_address(@page_profile),
                          @profile.user_id,
                          theme: theme_id
                        )
                      }
                      target="_blank"
                      rel="noopener noreferrer"
                      variant={:secondary}
                      icon="hero-eye"
                      class="flex-1"
                    >
                      {dgettext("dashboard_appearance", "Live Preview")}
                    </.action_link>
                  <% else %>
                    <%!-- `aria-disabled` rather than `disabled`, so the control
                        stays focusable and its tooltip says what unlocks it. --%>
                    <.action_button
                      variant={:secondary}
                      icon="hero-lock-closed"
                      class="flex-1 opacity-60"
                      aria-disabled="true"
                      title={dgettext("dashboard_appearance", "Connect Calendar to Preview")}
                    >
                      {dgettext("dashboard_appearance", "Live Preview")}
                    </.action_button>
                  <% end %>
                  <.action_button
                    icon="hero-adjustments-vertical"
                    class="flex-1"
                    phx-click="show_customization"
                    phx-value-theme={theme_id}
                    phx-target={@myself}
                  >
                    {dgettext("dashboard_appearance", "Customize Style")}
                  </.action_button>
                </div>
              </div>
            <% end %>
          </div>

          <.live_component
            module={BookingTextForm}
            id={"booking-text-form" <> page_suffix(@selected_page)}
            profile={@page_profile}
          />

          <.live_component
            module={PageSettingsComponent}
            id={"page-settings" <> page_suffix(@selected_page)}
            profile={@profile}
            page={@selected_page}
          />
        <% end %>
      </.dashboard_page>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("show_customization", %{"theme" => theme_id}, socket) do
    {:noreply, push_patch(socket, to: customize_path(theme_id, socket.assigns.selected_page))}
  end

  def handle_event("close_customization", _params, socket) do
    {:noreply, push_patch(socket, to: theme_path(socket.assigns.selected_page))}
  end

  def handle_event("select_theme", %{"theme" => theme_id}, socket) do
    if ThemeInfo.valid_theme_id?(theme_id) do
      case apply_theme(socket, socket.assigns.selected_page, theme_id) do
        {:ok, socket} ->
          theme_name = ThemeInfo.get_theme_name(socket.assigns.page_profile.booking_theme)

          {:noreply,
           Flash.put_flash(
             socket,
             :info,
             dgettext("dashboard_appearance", "Theme updated to %{theme_name}",
               theme_name: theme_name
             )
           )}

        {:error, _reason} ->
          {:noreply,
           Flash.put_flash(
             socket,
             :error,
             dgettext("dashboard_appearance", "Failed to update theme")
           )}
      end
    else
      {:noreply,
       Flash.put_flash(
         socket,
         :error,
         dgettext("dashboard_appearance", "Invalid theme selection")
       )}
    end
  end

  @doc """
  The Theme screen for `page`, or for the profile's own page when nil.
  """
  @spec theme_path(map() | nil) :: String.t()
  def theme_path(nil), do: ~p"/dashboard/theme"
  def theme_path(%{id: id}), do: ~p"/dashboard/theme?#{[page: id]}"

  defp customize_path(theme_id, nil), do: ~p"/dashboard/theme/customize/#{theme_id}"

  defp customize_path(theme_id, %{id: id}),
    do: ~p"/dashboard/theme/customize/#{theme_id}?#{[page: id]}"

  defp page_profile(profile, nil), do: profile
  defp page_profile(profile, page), do: BookingPages.apply_to_profile(profile, page)

  # The profile's own tab keeps the ids it always had; a page's tab gets its
  # own, so switching tabs mounts fresh editors instead of carrying state over.
  defp page_suffix(nil), do: ""
  defp page_suffix(%{id: id}), do: "-#{id}"

  defp apply_theme(socket, nil, theme_id) do
    with {:ok, updated_profile} <- Profiles.update_booking_theme(socket.assigns.profile, theme_id) do
      send(self(), {:profile_updated, updated_profile})
      {:ok, assign(socket, profile: updated_profile, page_profile: updated_profile)}
    end
  end

  # A page's theme is the page's own. The dashboard is not told: it holds the
  # profile, and handing it the page's look would make that the profile's.
  # The page is read afresh rather than taken from the assigns: the one held
  # here predates any texts the form below has saved since, and the form is
  # re-rendered from what this returns.
  defp apply_theme(socket, page, theme_id) do
    with {:ok, fresh} <- BookingPages.fetch(socket.assigns.profile.id, page.id),
         {:ok, page} <- BookingPages.update_theme(fresh, theme_id) do
      {:ok,
       assign(socket,
         selected_page: page,
         page_profile: BookingPages.apply_to_profile(socket.assigns.profile, page)
       )}
    end
  end
end
