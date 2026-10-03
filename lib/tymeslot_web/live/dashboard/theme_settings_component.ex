defmodule TymeslotWeb.Dashboard.ThemeSettingsComponent do
  @moduledoc """
  Theme selection component for the dashboard.
  Allows users to select their booking page theme.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias TymeslotWeb.Dashboard.ThemeSettings.BookingTextForm
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

    socket =
      socket
      |> assign(assigns)
      |> assign(:themes, ThemeInfo.theme_options())
      |> assign(:show_customization, show_customization)
      |> assign(:customization_theme_id, customization_theme_id)
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
            <.live_component
              module={ThemeCustomizationComponent}
              id={"theme-customization-#{@customization_theme_id}-#{@customization_timestamp}"}
              profile={@profile}
              theme_id={@customization_theme_id}
              parent_component={@myself}
            />
          </div>
        <% else %>
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
                    if(@profile.booking_theme == theme_id,
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
                      <%= if @profile.booking_theme == theme_id do %>
                        <div class="flex items-center gap-2 bg-turquoise-500 text-white px-4 py-1.5 rounded-token-full text-token-xs font-black uppercase tracking-wider shadow-lg">
                          <.icon name="hero-check" class="w-4 h-4" />
                          {dgettext("dashboard_appearance", "Current Style")}
                        </div>
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
                        PreviewMode.owner_path(@profile.username, @profile.user_id, theme: theme_id)
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
            id="booking-text-form"
            profile={@profile}
          />
        <% end %>
      </.dashboard_page>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("show_customization", %{"theme" => theme_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard/theme/customize/#{theme_id}")}
  end

  def handle_event("close_customization", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard/theme")}
  end

  def handle_event("select_theme", %{"theme" => theme_id}, socket) do
    if ThemeInfo.valid_theme_id?(theme_id) do
      case Profiles.update_booking_theme(socket.assigns.profile, theme_id) do
        {:ok, updated_profile} ->
          theme_name = ThemeInfo.get_theme_name(updated_profile.booking_theme)
          send(self(), {:profile_updated, updated_profile})

          {:noreply,
           socket
           |> assign(profile: updated_profile)
           |> Flash.put_flash(
             :info,
             dgettext("dashboard_appearance", "Theme updated to %{theme_name}",
               theme_name: theme_name
             )
           )}

        {:error, _changeset} ->
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
end
