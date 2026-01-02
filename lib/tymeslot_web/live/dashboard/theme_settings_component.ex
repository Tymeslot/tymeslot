defmodule TymeslotWeb.Dashboard.ThemeSettingsComponent do
  @moduledoc """
  Theme selection component for the dashboard.
  Allows users to select their booking page theme.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Security.ThemeInputProcessor
  alias Tymeslot.Themes.Theme
  alias TymeslotWeb.Dashboard.ThemeCustomizationComponent
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:themes, Theme.theme_options())
     |> assign_new(:show_customization, fn -> false end)
     |> assign_new(:customization_theme_id, fn -> nil end)
     |> assign_new(:customization_timestamp, fn -> nil end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <%= if @show_customization && @customization_theme_id do %>
        <.live_component
          module={ThemeCustomizationComponent}
          id={"theme-customization-#{@customization_theme_id}-#{@customization_timestamp}"}
          profile={@profile}
          theme_id={@customization_theme_id}
          parent_component={@myself}
          parent_uploads={@parent_uploads}
        />
      <% else %>
        <div class="mb-8">
          <h1 class="onboarding-title text-center mb-2">Choose Your Style</h1>
          <p class="onboarding-subtitle text-center">
            How do you want to present your brand and personality? Select the style that best represents you.
          </p>
        </div>

        <div class="grid md:grid-cols-2 gap-8">
          <%= for {theme_name, theme_id} <- @themes do %>
            <div class="space-y-4">
              <div
                class={[
                  "glass-morphism-card cursor-pointer transition-all hover-lift",
                  if(@profile.booking_theme == theme_id,
                    do: "turquoise-accent-border turquoise-glow selected-theme-card",
                    else: ""
                  )
                ]}
                phx-click="select_theme"
                phx-value-theme={theme_id}
                phx-target={@myself}
              >
                <div class={[
                  "p-6 transition-all duration-300",
                  if(@profile.booking_theme == theme_id,
                    do: "bg-gradient-to-br from-turquoise-50 to-blue-50 bg-opacity-80",
                    else: ""
                  )
                ]}>
                  <div class="flex items-center justify-between mb-4">
                    <h3 class="text-xl font-semibold">{theme_name}</h3>
                    <%= if @profile.booking_theme == theme_id do %>
                      <div class="flex items-center turquoise-accent">
                        <svg class="w-5 h-5 mr-2" fill="currentColor" viewBox="0 0 20 20">
                          <path
                            fill-rule="evenodd"
                            d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                            clip-rule="evenodd"
                          />
                        </svg>
                        <span class="text-sm font-medium">Current</span>
                      </div>
                    <% end %>
                  </div>

                  <div class="booking-flow-preview h-48 mb-4 rounded-lg overflow-hidden relative">
                    <.theme_preview theme_id={theme_id} />
                    <div
                      :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
                      class="absolute inset-0 bg-white/60 backdrop-blur-[2px] flex items-center justify-center cursor-not-allowed"
                      title={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
                    >
                      <div class="flex items-center gap-2 text-gray-600 text-sm">
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M13 16h-1v-4h-1m1-4h.01M12 18.5a6.5 6.5 0 110-13 6.5 6.5 0 010 13z"
                          >
                          </path>
                        </svg>
                        <span>Preview disabled</span>
                      </div>
                    </div>
                  </div>

                  <p class="text-sm">
                    {theme_description(theme_id)}
                  </p>
                </div>
              </div>

              <div class="flex gap-2">
                <%= if LinkAccessPolicy.can_link?(@profile, @integration_status) do %>
                  <button
                    type="button"
                    class="btn btn-secondary flex-1"
                    onclick={"window.open('#{LinkAccessPolicy.scheduling_path(@profile)}?theme=#{theme_id}', '_blank')"}
                    title="Open a preview of your scheduling page"
                  >
                    Preview
                  </button>
                <% else %>
                  <button
                    type="button"
                    class="btn btn-secondary flex-1 opacity-60 cursor-not-allowed"
                    disabled
                    title={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
                  >
                    Preview
                  </button>
                <% end %>
                <button
                  type="button"
                  class="btn btn-primary flex-1"
                  phx-click="show_customization"
                  phx-value-theme={theme_id}
                  phx-target={@myself}
                >
                  Customize
                </button>
              </div>
            </div>
          <% end %>
        </div>

        <div class="mt-8">
          <div class="glass-morphism-card bg-gradient-to-r from-turquoise-50 to-blue-50 border border-turquoise-200 bg-opacity-50">
            <div class="p-4">
              <div class="flex items-center justify-between">
                <div class="flex items-center space-x-3">
                  <div class="w-10 h-10 bg-gradient-to-br from-turquoise-500 to-blue-500 rounded-lg flex items-center justify-center flex-shrink-0">
                    <svg
                      class="w-5 h-5 text-white"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M11.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z"
                      />
                    </svg>
                  </div>
                  <div>
                    <h4 class="text-base font-semibold turquoise-accent">More Styles Coming Soon</h4>
                    <p class="text-sm text-gray-600">
                      We're crafting new themes to help you express your unique professional style.
                    </p>
                  </div>
                </div>
                <div class="flex space-x-1">
                  <div class="w-1.5 h-1.5 bg-turquoise-400 rounded-full animate-pulse"></div>
                  <div
                    class="w-1.5 h-1.5 bg-turquoise-400 rounded-full animate-pulse"
                    style="animation-delay: 0.5s"
                  >
                  </div>
                  <div
                    class="w-1.5 h-1.5 bg-turquoise-400 rounded-full animate-pulse"
                    style="animation-delay: 1s"
                  >
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("show_customization", %{"theme" => theme_id}, socket) do
    send(self(), {:theme_customization_opened, theme_id})

    {:noreply,
     socket
     |> assign(:show_customization, true)
     |> assign(:customization_theme_id, theme_id)
     |> assign(:customization_timestamp, System.system_time())}
  end

  def handle_event("close_customization", _params, socket) do
    send(self(), :theme_customization_closed)

    {:noreply,
     socket
     |> assign(:show_customization, false)
     |> assign(:customization_theme_id, nil)}
  end

  def handle_event("select_theme", %{"theme" => theme_id}, socket) do
    metadata = get_security_metadata(socket)

    case ThemeInputProcessor.validate_theme_selection(%{"theme" => theme_id}, metadata: metadata) do
      {:ok, %{"theme" => validated_theme_id}} ->
        case Profiles.update_booking_theme(socket.assigns.profile, validated_theme_id) do
          {:ok, updated_profile} ->
            theme_name = Theme.get_theme_name(updated_profile.booking_theme)
            send(self(), {:profile_updated, updated_profile})

            {:noreply,
             socket
             |> assign(profile: updated_profile)
             |> put_flash(:info, "Theme updated to #{theme_name}")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update theme")}
        end

      {:error, _validation_errors} ->
        {:noreply, put_flash(socket, :error, "Invalid theme selection")}
    end
  end

  defp theme_description("1") do
    "Glass morphism design with elegant transparency effects and a 4-step booking flow."
  end

  defp theme_description("2") do
    "Modern sliding design with video background and a 4-slide booking flow."
  end

  defp theme_description(_) do
    "A beautiful theme for your booking page."
  end

  defp theme_preview(assigns) do
    ~H"""
    <%= case @theme_id do %>
      <% "1" -> %>
        <div class="w-full h-full bg-gray-100 rounded-lg overflow-hidden">
          <img
            src="/images/ui/theme-previews/quill-theme-preview.webp"
            alt="Quill Theme Preview - Glass morphism booking flow"
            class="w-full h-full object-cover transition-transform duration-300 hover:scale-105"
            onerror="this.style.display='none'; this.nextElementSibling.style.display='flex'"
          />
          <!-- Fallback content when image fails to load -->
          <div
            class="w-full h-full bg-gradient-to-br from-purple-100 to-teal-100 flex items-center justify-center"
            style="display: none;"
          >
            <div class="text-center p-4">
              <div class="w-12 h-12 bg-teal-500 rounded-lg mx-auto mb-3 flex items-center justify-center">
                <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                  />
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
                  />
                </svg>
              </div>
              <p class="text-sm font-semibold text-gray-700">Quill Theme</p>
              <p class="text-xs text-gray-600">Glass morphism flow</p>
            </div>
          </div>
        </div>
      <% "2" -> %>
        <div class="w-full h-full bg-gray-100 rounded-lg overflow-hidden">
          <img
            src="/images/ui/theme-previews/rhythm-theme-preview.webp"
            alt="Rhythm Theme Preview - Video background sliding flow"
            class="w-full h-full object-cover transition-transform duration-300 hover:scale-105"
            onerror="this.style.display='none'; this.nextElementSibling.style.display='flex'"
          />
          <!-- Fallback content when image fails to load -->
          <div
            class="w-full h-full bg-gradient-to-br from-purple-100 to-pink-100 flex items-center justify-center"
            style="display: none;"
          >
            <div class="text-center p-4">
              <div class="w-12 h-12 bg-purple-500 rounded-lg mx-auto mb-3 flex items-center justify-center">
                <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M7 4v16l13-8L7 4z"
                  />
                </svg>
              </div>
              <p class="text-sm font-semibold text-gray-700">Rhythm Theme</p>
              <p class="text-xs text-gray-600">Video sliding flow</p>
            </div>
          </div>
        </div>
      <% _ -> %>
        <div class="w-full h-full bg-gray-100 flex items-center justify-center rounded-lg">
          <div class="text-center text-gray-500">
            <svg class="w-12 h-12 mx-auto mb-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="1"
                d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2 2v12a2 2 0 002 2z"
              />
            </svg>
            <div class="text-sm">Theme Preview</div>
          </div>
        </div>
    <% end %>
    """
  end

  # Helper function to get security metadata
  defp get_security_metadata(socket) do
    DashboardHelpers.get_security_metadata(socket)
  end
end
