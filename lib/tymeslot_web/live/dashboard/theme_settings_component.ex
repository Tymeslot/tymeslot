defmodule TymeslotWeb.Dashboard.ThemeSettingsComponent do
  @moduledoc """
  Theme selection component for the dashboard.
  Allows users to select their booking page theme.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationComponent
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemePreview
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
    <div class="space-y-10 pb-20">
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
        <.section_header icon={:paint_brush} title="Choose Your Style" />

        <div class="-mt-8 mb-16 max-w-2xl">
          <p class="text-xl text-tymeslot-500 font-medium leading-relaxed">
            Select the interface that best represents your personal brand and creates the best experience for your clients.
          </p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-10">
          <%= for {theme_name, theme_id} <- @themes do %>
            <div class="group/theme space-y-6">
              <div
                class={[
                  "card-glass p-0 overflow-hidden cursor-pointer transition-all duration-500 border-2",
                  if(@profile.booking_theme == theme_id,
                    do:
                      "glass-gradient border-turquoise-400 shadow-2xl shadow-turquoise-500/20 ring-4 ring-turquoise-50",
                    else:
                      "border-tymeslot-50 hover:border-turquoise-200 hover:shadow-xl hover:shadow-tymeslot-200/50"
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
                    <h3 class="text-token-2xl font-black text-white tracking-tight drop-shadow-md">
                      {theme_name}
                    </h3>
                    <%= if @profile.booking_theme == theme_id do %>
                      <div class="flex items-center gap-2 bg-turquoise-500 text-white px-4 py-1.5 rounded-full text-token-xs font-black uppercase tracking-wider shadow-lg">
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="3"
                            d="M5 13l4 4L19 7"
                          />
                        </svg>
                        Current Style
                      </div>
                    <% end %>
                  </div>

                  <div
                    :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
                    class="absolute inset-0 bg-tymeslot-900/40 backdrop-blur-[2px] flex flex-col items-center justify-center cursor-not-allowed z-20"
                  >
                    <div class="w-12 h-12 bg-white/20 rounded-token-2xl flex items-center justify-center mb-3">
                      <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2.5"
                          d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                        />
                      </svg>
                    </div>
                    <span class="text-white font-black text-token-xs uppercase tracking-widest">
                      Connect Calendar to Preview
                    </span>
                  </div>
                </div>

                <div class="p-8">
                  <p class="text-tymeslot-600 font-medium leading-relaxed line-clamp-2">
                    {ThemeInfo.get_description(theme_id)}
                  </p>
                </div>
              </div>

              <div class="flex gap-4">
                <%= if LinkAccessPolicy.can_link?(@profile, @integration_status) do %>
                  <button
                    type="button"
                    class="btn btn-secondary flex-1 py-3 px-4 text-token-sm"
                    onclick={"window.open('#{LinkAccessPolicy.scheduling_path(@profile)}?theme=#{theme_id}', '_blank')"}
                  >
                    <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2.5"
                        d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                      />
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2.5"
                        d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
                      />
                    </svg>
                    Live Preview
                  </button>
                <% else %>
                  <button
                    type="button"
                    class="btn btn-secondary flex-1 py-3 px-4 text-token-sm opacity-50 cursor-not-allowed"
                    disabled
                    title="Connect Calendar to Preview"
                  >
                    <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2.5"
                        d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                      />
                    </svg>
                    Live Preview
                  </button>
                <% end %>
                <button
                  type="button"
                  class="btn btn-primary flex-1 py-3 px-4 text-token-sm"
                  phx-click="show_customization"
                  phx-value-theme={theme_id}
                  phx-target={@myself}
                >
                  <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2.5"
                      d="M12 6V4m0 2a2 2 0 100 4m0-4a2 2 0 110 4m-6 8a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4m6 6v10m6-2a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4"
                    />
                  </svg>
                  Customize Style
                </button>
              </div>
            </div>
          <% end %>
        </div>

        <div class="mt-16 bg-tymeslot-50 border-2 border-dashed border-tymeslot-200 rounded-token-3xl p-8 relative overflow-hidden group">
          <div class="absolute top-0 right-0 p-4 opacity-10 group-hover:rotate-12 transition-transform duration-700">
            <svg class="w-32 h-32 text-tymeslot-900" fill="currentColor" viewBox="0 0 24 24">
              <path d="M11.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z" />
            </svg>
          </div>
          <div class="relative z-10">
            <h4 class="text-token-2xl font-black text-tymeslot-900 tracking-tight mb-2">
              More Styles Coming Soon
            </h4>
            <p class="text-tymeslot-500 font-medium text-token-lg mb-6">
              Our design team is busy crafting new themes to help you express your unique professional style.
            </p>
            <div class="flex gap-2">
              <div class="w-2 h-2 bg-turquoise-400 rounded-full animate-bounce"></div>
              <div class="w-2 h-2 bg-turquoise-400 rounded-full animate-bounce [animation-delay:0.2s]">
              </div>
              <div class="w-2 h-2 bg-turquoise-400 rounded-full animate-bounce [animation-delay:0.4s]">
              </div>
            </div>
          </div>
        </div>
      <% end %>
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
           |> Flash.put_flash(:info, "Theme updated to #{theme_name}")}

        {:error, _changeset} ->
          {:noreply, Flash.put_flash(socket, :error, "Failed to update theme")}
      end
    else
      {:noreply, Flash.put_flash(socket, :error, "Invalid theme selection")}
    end
  end
end
