defmodule TymeslotWeb.Dashboard.ThemeCustomizationComponent do
  @moduledoc """
  Theme customization component for advanced theme settings.
  Allows users to customize colors and backgrounds for their booking page.

  Assigns contract
  - Required (passed in):
    - profile: Tymeslot.DatabaseSchemas.ProfileSchema.t()
    - theme_id: String.t()
  - Provided/managed by this component (do not pass these in):
    - customization: map with current customization state (see customization_t())
    - presets: preset collections for color schemes and backgrounds (see presets_t())
    - defaults: map of default values for the theme
    - browsing_type: String.t() – which background category is currently browsed ("gradient" | "color" | "image" | "video")
    - parent_uploads: map() | nil – upload entries provided by parent LiveView (optional)
    - parent_component: term() – reference to parent component for close actions (optional)
  """
  use TymeslotWeb, :live_component

  import TymeslotWeb.Components.UI.CloseButton
  import TymeslotWeb.Dashboard.ThemeCustomization.Pickers.ColorPicker, only: [color_picker: 1]

  import TymeslotWeb.Dashboard.ThemeCustomization.Pickers.GradientPicker,
    only: [gradient_picker: 1]

  import TymeslotWeb.Dashboard.ThemeCustomization.Pickers.ImagePicker, only: [image_picker: 1]
  import TymeslotWeb.Dashboard.ThemeCustomization.Pickers.VideoPicker, only: [video_picker: 1]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.ThemeCustomizations

  @typedoc "Preset collections used by the component"
  @type presets_t :: %{
          required(:color_schemes) => %{optional(String.t()) => map()},
          required(:gradients) => %{
            optional(String.t()) => %{
              required(:name) => String.t(),
              required(:value) => String.t()
            }
          },
          required(:images) => %{
            optional(String.t()) => %{
              required(:name) => String.t(),
              required(:file) => String.t(),
              optional(:description) => String.t()
            }
          },
          required(:videos) => %{
            optional(String.t()) => %{
              required(:name) => String.t(),
              required(:file) => String.t(),
              required(:thumbnail) => String.t(),
              optional(:description) => String.t()
            }
          }
        }

  @typedoc "Customization map applied to the theme"
  @type customization_t :: %{
          required(:background_type) => String.t(),
          optional(:background_value) => String.t() | nil,
          optional(:background_image_path) => String.t() | nil,
          optional(:background_video_path) => String.t() | nil,
          optional(:color_scheme) => String.t()
        }

  @typedoc "Assigns contract for this component"
  @type assigns_t :: %{
          required(:profile) => Tymeslot.DatabaseSchemas.ProfileSchema.t(),
          required(:theme_id) => String.t(),
          required(:customization) => customization_t(),
          required(:presets) => presets_t(),
          required(:defaults) => map(),
          required(:browsing_type) => String.t(),
          optional(:parent_uploads) => map() | nil,
          optional(:parent_component) => term()
        }

  @impl true
  @spec mount(Socket.t()) :: {:ok, Socket.t()}
  def mount(socket) do
    {:ok, assign(socket, :uploading, false)}
  end

  @impl true
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(assigns, socket) do
    theme_id = assigns[:theme_id] || "1"

    # Initialize customization data from the domain
    %{
      customization: customization,
      original: _original_state,
      presets: presets,
      defaults: defaults
    } = ThemeCustomizations.initialize_customization(assigns.profile.id, theme_id)

    # Narrow assigns surface: expose a small, consistent contract
    {:ok,
     socket
     |> assign(:profile, assigns.profile)
     |> assign(:parent_component, assigns[:parent_component])
     |> assign(:parent_uploads, assigns[:parent_uploads] || nil)
     |> assign(:theme_id, theme_id)
     |> assign(:customization, customization)
     |> assign(:presets, presets)
     |> assign(:defaults, defaults)
     |> assign(:browsing_type, customization.background_type)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8" phx-hook="AutoUpload" id="theme-customization-uploads">
      <.toolbar profile={@profile} theme_id={@theme_id} parent_component={@parent_component} />

      <.color_scheme_section customization={@customization} presets={@presets} myself={@myself} />

      <.background_section
        browsing_type={@browsing_type}
        customization={@customization}
        presets={@presets}
        parent_uploads={@parent_uploads}
        myself={@myself}
      />
    </div>
    """
  end

  @impl true
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("theme:select_color_scheme", %{"scheme" => scheme_id}, socket) do
    case ThemeCustomizations.apply_color_scheme_change(
           socket.assigns.profile.id,
           socket.assigns.theme_id,
           socket.assigns.customization,
           scheme_id
         ) do
      {:ok, updated_customization} ->
        {:noreply, assign(socket, :customization, updated_customization)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("theme:set_browsing_type", %{"type" => type}, socket) do
    # Only update the browsing type - this is just UI navigation, not a selection
    {:noreply, assign(socket, :browsing_type, type)}
  end

  def handle_event("theme:select_background", params, socket) do
    type = params["type"]
    value = params["id"] || params["value"]

    case ThemeCustomizations.apply_background_change(
           socket.assigns.profile.id,
           socket.assigns.theme_id,
           socket.assigns.customization,
           type,
           value
         ) do
      {:ok, updated_customization} ->
        {:noreply,
         socket
         |> assign(:customization, updated_customization)
         |> assign(:browsing_type, type)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  # ========== Function components (extracted) ==========

  defp toolbar(assigns) do
    ~H"""
    <div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
      <div class="flex flex-col sm:flex-row sm:items-center gap-4">
        <%= if @profile && @profile.username do %>
          <button
            type="button"
            class="btn btn-secondary flex items-center gap-2 self-start"
            onclick={"window.open('/#{@profile.username}?theme=#{@theme_id}', '_blank')"}
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
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
            <span class="hidden sm:inline">Preview Theme</span>
            <span class="sm:hidden">Preview</span>
          </button>
        <% end %>
        <h2 class="text-xl sm:text-2xl font-bold">Customize Theme</h2>
      </div>

      <.close_button
        phx_click="close_customization"
        phx_target={@parent_component}
        title="Close"
        show_label={true}
        class="self-start sm:self-auto"
      />
    </div>
    """
  end

  defp color_scheme_section(assigns) do
    ~H"""
    <div class="glass-morphism-card p-6">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-lg font-semibold">Color Scheme</h3>
        <% current_scheme = @presets.color_schemes[@customization.color_scheme] %>
        <%= if current_scheme do %>
          <div class="color-scheme-current">
            <span>Current:</span>
            <div class="color-scheme-preview">
              <div class="color-dot-sm" style={"background-color: #{current_scheme.colors.primary}"}>
              </div>
              <div class="color-dot-sm" style={"background-color: #{current_scheme.colors.secondary}"}>
              </div>
              <div class="color-dot-sm" style={"background-color: #{current_scheme.colors.accent}"}>
              </div>
            </div>
            <span class="font-medium">{current_scheme.name}</span>
          </div>
        <% end %>
      </div>
      <div class="theme-selection-grid cols-4">
        <%= for {scheme_id, scheme} <- @presets.color_schemes do %>
          <button
            type="button"
            class={[
              "duration-card theme-selection-button relative block rounded-md border p-3 transition shadow-sm ring-1 ring-gray-300 hover:ring-turquoise-300 hover:shadow",
              if(@customization.color_scheme == scheme_id,
                do: "selected turquoise-glow ring-2 ring-turquoise-500 border-turquoise-500",
                else: "border-gray-200"
              )
            ]}
            phx-click="theme:select_color_scheme"
            phx-value-scheme={scheme_id}
            phx-target={@myself}
          >
            <div class="color-scheme-preview">
              <div class="color-dot" style={"background-color: #{scheme.colors.primary}"}></div>
              <div class="color-dot" style={"background-color: #{scheme.colors.secondary}"}></div>
              <div class="color-dot" style={"background-color: #{scheme.colors.accent}"}></div>
            </div>
            <p class="theme-selection-label">{scheme.name}</p>
            <%= if @customization.color_scheme == scheme_id do %>
              <div class="selection-indicator">
                <svg class="w-4 h-4 text-turquoise-500" fill="currentColor" viewBox="0 0 20 20">
                  <path
                    fill-rule="evenodd"
                    d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                    clip-rule="evenodd"
                  />
                </svg>
              </div>
            <% end %>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp background_section(assigns) do
    ~H"""
    <div class="glass-morphism-card p-6">
      <h3 class="text-lg font-semibold mb-4">Background Style</h3>

      <div class="theme-section">
        <div class="theme-selection-grid cols-4">
          <%= for {type, icon_path, label} <- background_tabs() do %>
            <button
              type="button"
              class={[
                "duration-card theme-selection-button relative block rounded-md border p-3 transition shadow-sm ring-1 ring-gray-300 hover:ring-turquoise-300 hover:shadow",
                if(@browsing_type == type,
                  do: "selected turquoise-glow ring-2 ring-turquoise-500 border-turquoise-500",
                  else: "border-gray-200"
                )
              ]}
              phx-click="theme:set_browsing_type"
              phx-value-type={type}
              phx-target={@myself}
            >
              <svg class="theme-selection-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d={icon_path} />
              </svg>
              <span class="theme-selection-label">{label}</span>
              <%= if @browsing_type == type do %>
                <div class="selection-indicator">
                  <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                    <path
                      fill-rule="evenodd"
                      d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                      clip-rule="evenodd"
                    />
                  </svg>
                </div>
              <% end %>
            </button>
          <% end %>
        </div>

        <div class="mt-6">
          <%= case @browsing_type do %>
            <% "gradient" -> %>
              <.gradient_picker customization={@customization} presets={@presets} myself={@myself} />
            <% "color" -> %>
              <.color_picker customization={@customization} myself={@myself} />
            <% "image" -> %>
              <.image_picker
                customization={@customization}
                presets={@presets}
                parent_uploads={@parent_uploads}
                myself={@myself}
              />
            <% "video" -> %>
              <.video_picker
                customization={@customization}
                presets={@presets}
                parent_uploads={@parent_uploads}
                myself={@myself}
              />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp background_tabs do
    [
      {"gradient", "M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4", "Gradient"},
      {"color",
       "M7 21a4 4 0 01-4-4V5a2 2 0 012-2h4a2 2 0 012 2v12a4 4 0 01-4 4zm0 0h12a2 2 0 002-2v-4a6 6 0 00-3-5.197M11 3h8a2 2 0 012 2v4a6 6 0 01-3 5.197",
       "Solid Color"},
      {"image",
       "M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z",
       "Image"},
      {"video",
       "M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z",
       "Video"}
    ]
  end
end
