defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ImagePicker do
  @moduledoc """
  Function component for selecting or uploading image backgrounds in theme customization.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ThemeCustomizations.Options.Background

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ImageUpload,
    only: [image_upload: 1]

  @doc """
  Renders the image picker.
  Expects assigns: option, customization, presets (the group's images as `{id, preset}`, in order), uploads, myself
  """
  @spec image_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def image_picker(assigns) do
    ~H"""
    <div class="space-y-10">
      <div>
        <p class="text-token-sm font-black text-tymeslot-400 uppercase tracking-widest mb-6">
          {dgettext("dashboard_appearance", "Choose from our collection")}
        </p>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
          <%= for {image_id, image} <- @presets do %>
            <button
              type="button"
              class={[
                "group/image relative flex flex-col rounded-token-2xl overflow-hidden border-4 transition-all duration-500",
                if(@customization.settings["background_value"] == image_id,
                  do: "border-turquoise-400 shadow-2xl shadow-turquoise-500/20 scale-[1.02]",
                  else:
                    "border-white hover:border-turquoise-200 hover:shadow-xl hover:shadow-tymeslot-200/50"
                )
              ]}
              phx-click="theme:set_option"
              phx-value-option={@option}
              phx-value-field="image"
              phx-value-choice={image_id}
              phx-target={@myself}
            >
              <div class="aspect-video relative overflow-hidden">
                <img
                  src={Background.preset_image_url(image.file)}
                  alt={image.name}
                  class="w-full h-full object-cover transition-transform duration-700 group-hover/image:scale-110"
                  data-img-fallback
                />
                <div class="absolute inset-0 bg-linear-to-br from-tymeslot-100 to-tymeslot-200 items-center justify-center hidden">
                  <.icon name="hero-photo" class="w-12 h-12 text-tymeslot-300" />
                </div>
                <%= if @customization.settings["background_value"] == image_id do %>
                  <div class="absolute top-3 right-3 w-8 h-8 bg-turquoise-500 text-white rounded-token-full flex items-center justify-center shadow-lg z-10">
                    <.icon name="hero-check" class="w-5 h-5" />
                  </div>
                <% end %>
              </div>
              <div class={[
                "p-5 text-left transition-colors",
                if(@customization.settings["background_value"] == image_id,
                  do: "bg-turquoise-50",
                  else: "bg-white"
                )
              ]}>
                <p class="text-token-base font-black text-tymeslot-900 tracking-tight">
                  {image.name}
                </p>
                <p class="text-token-xs text-tymeslot-500 font-bold uppercase tracking-widest mt-1">
                  {image.description}
                </p>
              </div>
            </button>
          <% end %>
        </div>
      </div>

      <div class="relative py-4">
        <div class="absolute inset-0 flex items-center" aria-hidden="true">
          <div class="w-full border-t-2 border-tymeslot-100"></div>
        </div>
        <div class="relative flex justify-center text-token-sm font-black uppercase tracking-[0.2em]">
          <span class="px-6 bg-white text-tymeslot-400">
            {dgettext("dashboard_appearance", "Or upload your own")}
          </span>
        </div>
      </div>

      <div class="bg-tymeslot-50 p-8 rounded-token-4xl border-2 border-tymeslot-100 border-dashed">
        <.image_upload
          id="theme-background-image-form"
          field={:background_image_path}
          uploads={@uploads}
          myself={@myself}
        />

        <%= if @customization.settings["background_image_path"] && @customization.settings["background_value"] == "custom" do %>
          <div class="mt-8 p-4 bg-amber-50 border border-amber-100 rounded-token-2xl flex items-center gap-3">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-amber-600 shrink-0" />
            <p class="text-token-sm font-bold text-amber-800">
              {dgettext(
                "dashboard_appearance",
                "You have a custom image. Selecting a preset will remove it."
              )}
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
