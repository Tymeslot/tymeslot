defmodule TymeslotWeb.Dashboard.ThemeCustomization.Pickers.ImagePicker do
  @moduledoc """
  Function component for selecting or uploading image backgrounds in theme customization.
  """
  use TymeslotWeb, :html

  @doc """
  Renders the image picker.
  Expects assigns: customization, presets, parent_uploads, myself
  """
  @spec image_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def image_picker(assigns) do
    ~H"""
    <div class="theme-section">
      <div>
        <h4 class="text-sm font-medium text-gray-700 mb-3">Choose from our collection:</h4>
        <div class="theme-selection-grid cols-3">
          <%= for {image_id, image} <- @presets.images do %>
            <button
              type="button"
              class={[
                "duration-card hover-lift relative block rounded-lg border transition shadow-sm ring-1 ring-gray-300 hover:ring-turquoise-300 hover:shadow",
                if(@customization.background_value == image_id,
                  do: "selected turquoise-glow ring-2 ring-turquoise-500 border-turquoise-500",
                  else: "border-gray-200"
                )
              ]}
              phx-click="theme:select_background"
              phx-value-type="image"
              phx-value-id={image_id}
              phx-target={@myself}
            >
              <div class="background-preview-large relative">
                <img
                  src={"/images/ui/backgrounds/#{image.file}"}
                  alt={image.name}
                  class="w-full h-full object-cover"
                  onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';"
                />
                <div class="absolute inset-0 bg-gradient-to-br from-gray-100 to-gray-300 items-center justify-center hidden">
                  <svg
                    class="w-12 h-12 text-gray-400"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"
                    />
                  </svg>
                </div>
                <%= if @customization.background_value == image_id do %>
                  <div class="absolute inset-0 bg-turquoise-50/20 pointer-events-none"></div>
                <% end %>
              </div>
              <div class={[
                "p-3",
                if(@customization.background_value == image_id,
                  do: "bg-turquoise-50",
                  else: "bg-white"
                )
              ]}>
                <p class="text-sm font-medium text-gray-900">{image.name}</p>
                <p class="text-xs text-gray-500 mt-1">{image.description}</p>
              </div>
              <%= if @customization.background_value == image_id do %>
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
          id="theme-background-image-form"
          phx-submit="save_background_image"
          phx-change="validate_image"
          data-auto-upload="true"
        >
          <div class="space-y-4">
            <%= if @parent_uploads && @parent_uploads[:background_image] do %>
              <.live_file_input upload={@parent_uploads.background_image} class="file-input" />
            <% else %>
              <div class="text-gray-500 text-sm">Upload not available</div>
            <% end %>

            <%= if @parent_uploads && @parent_uploads[:background_image] do %>
              <%= for entry <- @parent_uploads.background_image.entries do %>
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
            <button type="submit" id="theme-image-submit-btn" style="display: none;">
              Upload Image
            </button>
          </div>
        </form>

        <%= if @customization.background_image_path && @customization.background_value == "custom" do %>
          <div class="mt-4 p-3 bg-yellow-50 rounded-lg">
            <p class="text-sm text-yellow-800">
              <svg class="w-4 h-4 inline mr-1" fill="currentColor" viewBox="0 0 20 20">
                <path
                  fill-rule="evenodd"
                  d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                  clip-rule="evenodd"
                />
              </svg>
              You have a custom image uploaded. Selecting a preset will remove it.
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
