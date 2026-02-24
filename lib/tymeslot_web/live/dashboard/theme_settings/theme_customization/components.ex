defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components do
  @moduledoc """
  UI components for theme customization.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Scheduling.LinkAccessPolicy

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColorPicker,
    only: [color_picker: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.GradientPicker,
    only: [gradient_picker: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ImagePicker,
    only: [image_picker: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.VideoPicker,
    only: [video_picker: 1]

  @spec toolbar(map()) :: Phoenix.LiveView.Rendered.t()
  def toolbar(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-6 mb-10">
      <.section_header icon={:paint_brush} title="Customize Style" class="mb-0" />

      <div class="flex items-center justify-between gap-3 md:justify-start">
        <%= if @profile && @profile.username do %>
          <button
            type="button"
            class="btn btn-secondary py-2.5 px-5 text-token-sm"
            onclick={"window.open('#{LinkAccessPolicy.scheduling_path(@profile)}?theme=#{@theme_id}', '_blank')"}
          >
            <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
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
        <% end %>
        <button
          phx-click="close_customization"
          phx-target={@parent_component}
          class="flex items-center gap-2 px-5 py-2.5 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all border-2 border-transparent hover:border-tymeslot-200"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
          </svg>
          Close
        </button>
      </div>
    </div>
    """
  end

  @spec color_scheme_section(map()) :: Phoenix.LiveView.Rendered.t()
  def color_scheme_section(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between mb-8 gap-4">
        <div>
          <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">Color Palette</h3>
          <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
            Select the primary colors for your booking page interface.
          </p>
        </div>
        <% current_scheme = @presets.color_schemes[@customization.color_scheme] %>
        <%= if current_scheme do %>
          <div class="flex items-center gap-3 bg-tymeslot-50 px-4 py-2 rounded-token-2xl border border-tymeslot-100 shadow-inner">
            <span class="text-[10px] font-black uppercase tracking-widest text-tymeslot-400">Current</span>
            <div class="flex items-center gap-1.5 bg-white p-1 rounded-token-lg border border-tymeslot-100">
              <div class="w-3 h-3 rounded-full" style={"background-color: #{current_scheme.colors.primary}"}>
              </div>
              <div
                class="w-3 h-3 rounded-full"
                style={"background-color: #{current_scheme.colors.secondary}"}
              >
              </div>
              <div class="w-3 h-3 rounded-full" style={"background-color: #{current_scheme.colors.accent}"}>
              </div>
            </div>
            <span class="text-token-sm font-black text-tymeslot-700">{current_scheme.name}</span>
          </div>
        <% end %>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
        <%= for {scheme_id, scheme} <- @presets.color_schemes do %>
          <button
            type="button"
            class={[
              "group/scheme relative flex flex-col items-center p-4 rounded-token-2xl border-2 transition-all duration-300",
              if(@customization.color_scheme == scheme_id,
                do: "bg-turquoise-50 border-turquoise-400 shadow-xl shadow-turquoise-500/10",
                else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
              )
            ]}
            phx-click="theme:select_color_scheme"
            phx-value-scheme={scheme_id}
            phx-target={@myself}
          >
            <div class="flex items-center gap-2 mb-4 bg-tymeslot-50/50 p-2 rounded-token-xl group-hover/scheme:scale-110 transition-transform">
              <div
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{scheme.colors.primary}"}
              >
              </div>
              <div
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{scheme.colors.secondary}"}
              >
              </div>
              <div
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{scheme.colors.accent}"}
              >
              </div>
            </div>
            <p class={[
              "text-token-sm font-black uppercase tracking-widest transition-colors",
              if(@customization.color_scheme == scheme_id,
                do: "text-turquoise-700",
                else: "text-tymeslot-400 group-hover/scheme:text-tymeslot-600"
              )
            ]}>
              {scheme.name}
            </p>

            <%= if @customization.color_scheme == scheme_id do %>
              <div class="absolute top-2 right-2 w-6 h-6 bg-turquoise-500 text-white rounded-full flex items-center justify-center shadow-lg animate-in zoom-in">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7" />
                </svg>
              </div>
            <% end %>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  @spec background_section(map()) :: Phoenix.LiveView.Rendered.t()
  def background_section(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="mb-8">
        <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">Background Design</h3>
        <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
          Choose a visual style that matches your professional identity.
        </p>
      </div>

      <div class="space-y-10">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 bg-tymeslot-50/50 p-2 rounded-[1.5rem] border-2 border-tymeslot-50">
          <%= for {type, icon_path, label} <- background_tabs() do %>
            <button
              type="button"
              class={[
                "flex items-center justify-center gap-2 px-4 py-3 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 whitespace-nowrap",
                if(@browsing_type == type,
                  do: "bg-white border-white text-turquoise-600 shadow-xl shadow-tymeslot-200/50 scale-[1.02]",
                  else: "bg-transparent border-transparent text-tymeslot-400 hover:text-tymeslot-600 hover:bg-white/50"
                )
              ]}
              phx-click="theme:set_browsing_type"
              phx-value-type={type}
              phx-target={@myself}
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d={icon_path} />
              </svg>
              <span>{label}</span>
            </button>
          <% end %>
        </div>

        <div class="animate-in fade-in slide-in-from-top-4 duration-500">
          <%= case @browsing_type do %>
            <% "gradient" -> %>
              <.gradient_picker customization={@customization} presets={@presets} myself={@myself} />
            <% "color" -> %>
              <.color_picker customization={@customization} myself={@myself} />
            <% "image" -> %>
              <.image_picker
                customization={@customization}
                presets={@presets}
                uploads={@uploads}
                myself={@myself}
              />
            <% "video" -> %>
              <.video_picker
                customization={@customization}
                presets={@presets}
                uploads={@uploads}
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
