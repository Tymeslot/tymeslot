defmodule TymeslotWeb.Dashboard.ThemeCustomization.Pickers.VideoPicker do
  @moduledoc """
  Function component for selecting or uploading video backgrounds in theme customization.
  """
  use TymeslotWeb, :html

  @doc """
  Renders the video picker.
  Expects assigns: customization, presets, parent_uploads, myself
  """
  @spec video_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def video_picker(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h4 class="text-sm font-medium text-gray-700 mb-3">Choose from our collection:</h4>
        <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
          <%= for {video_id, video} <- @presets.videos do %>
            <button
              type="button"
              class={[
                "relative group overflow-hidden rounded-lg transition-all hover-lift border ring-1 ring-gray-300 hover:ring-turquoise-300",
                if(@customization.background_value == video_id,
                  do: "ring-2 ring-turquoise-500 turquoise-glow border-turquoise-500",
                  else: "border-gray-200"
                )
              ]}
              phx-click="theme:select_background"
              phx-value-type="video"
              phx-value-id={video_id}
              phx-target={@myself}
            >
              <div
                class="aspect-video bg-gray-900 relative overflow-hidden video-hover-container"
                onmouseenter="this.querySelector('.video-preview').currentTime=0; this.querySelector('.video-preview').play().catch(()=>{});"
                onmouseleave="this.querySelector('.video-preview').pause();"
              >
                <img
                  src={"/videos/thumbnails/#{video.thumbnail}"}
                  alt={video.name}
                  class="video-thumbnail w-full h-full object-cover absolute inset-0 z-10"
                  onerror="this.style.display='none'; this.parentElement.querySelector('.fallback-thumbnail').style.display='flex';"
                />
                <video
                  src={"/videos/backgrounds/#{video.file}"}
                  class="video-preview w-full h-full object-cover absolute inset-0 opacity-0"
                  muted
                  loop
                  playsinline
                  preload="metadata"
                >
                </video>
                <div class="fallback-thumbnail absolute inset-0 bg-gradient-to-br from-gray-800 to-gray-900 items-center justify-center hidden z-10">
                  <svg
                    class="w-12 h-12 text-gray-600"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"
                    />
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                </div>
                <div class="play-icon-overlay absolute inset-0 bg-black bg-opacity-0 group-hover:bg-opacity-10 transition-all duration-300 flex items-center justify-center z-20 pointer-events-none">
                  <div class="opacity-60 transition-opacity duration-300">
                    <svg
                      class="w-8 h-8 text-white drop-shadow-lg"
                      fill="currentColor"
                      viewBox="0 0 20 20"
                    >
                      <path
                        fill-rule="evenodd"
                        d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                </div>
                <%= if @customization.background_value == video_id do %>
                  <div class="absolute inset-0 bg-turquoise-50/20 pointer-events-none z-20"></div>
                <% end %>
              </div>
              <div class={[
                "p-3",
                if(@customization.background_value == video_id,
                  do: "bg-turquoise-50",
                  else: "bg-white"
                )
              ]}>
                <p class="text-sm font-medium text-gray-900">{video.name}</p>
                <p class="text-xs text-gray-500 mt-1">{video.description}</p>
              </div>
              <%= if @customization.background_value == video_id do %>
                <div class="absolute top-2 right-2">
                  <div class="bg-turquoise-500 text-white rounded-full p-1">
                    <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                </div>
              <% end %>
            </button>
          <% end %>
        </div>
      </div>

      <div class="relative">
        <div class="absolute inset-0 flex items-center">
          <div class="w-full border-t border-gray-300"></div>
        </div>
        <div class="relative flex justify-center text-sm">
          <span class="px-2 bg-white text-gray-500">Or upload your own</span>
        </div>
      </div>

      <div>
        <form
          id="theme-background-video-form"
          phx-submit="save_background_video"
          phx-change="validate_video"
          data-auto-upload="true"
        >
          <div class="space-y-4">
            <%= if @parent_uploads && @parent_uploads[:background_video] do %>
              <.live_file_input upload={@parent_uploads.background_video} class="file-input" />
            <% else %>
              <div class="text-gray-500 text-sm">Upload not available</div>
            <% end %>

            <%= if @parent_uploads && @parent_uploads[:background_video] do %>
              <%= for entry <- @parent_uploads.background_video.entries do %>
                <div class="flex items-center justify-between p-3 bg-gray-50 rounded-lg">
                  <span class="text-sm">{entry.client_name}</span>
                  <div class="flex items-center">
                    <span class="text-gray-500 text-sm mr-2">{entry.progress}%</span>
                    <div class="w-24 bg-gray-200 rounded-full h-2">
                      <div
                        class="bg-turquoise-500 h-2 rounded-full transition-all duration-300"
                        style={"width: #{entry.progress}%"}
                      >
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
            <button type="submit" id="theme-video-submit-btn" style="display: none;">
              Upload Video
            </button>
          </div>
        </form>

        <%= if @customization.background_video_path && @customization.background_value == "custom" do %>
          <div class="mt-4 p-3 bg-yellow-50 rounded-lg">
            <p class="text-sm text-yellow-800">
              <svg class="w-4 h-4 inline mr-1" fill="currentColor" viewBox="0 0 20 20">
                <path
                  fill-rule="evenodd"
                  d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                  clip-rule="evenodd"
                />
              </svg>
              You have a custom video uploaded. Selecting a preset will remove it.
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
