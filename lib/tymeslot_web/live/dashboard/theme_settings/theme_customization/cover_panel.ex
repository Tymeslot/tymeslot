defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CoverPanel do
  @moduledoc """
  The dashboard panel for an `Options.Cover` group: the group's preset
  covers (`theme:set_option` on `cover_value`, which also drops an uploaded
  cover and so deletes its file) and an upload form making an image of the
  organiser's own the cover (`upload_asset` into `cover_path`). It keeps no
  UI state, so the `Panel` defaults for `ui/3`, `handle_ui/5` and
  `telemetry/3` stand.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations.Options.Cover
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ImageUpload,
    only: [image_upload: 1]

  @impl Panel
  def render(assigns) do
    assigns =
      assign(assigns, :current, Cover.media(assigns.customization.settings, assigns.group).cover)

    ~H"""
    <.card
      title={dgettext("dashboard_appearance", "Cover Image")}
      description={
        dgettext(
          "dashboard_appearance",
          "The wide image across the top of your booking page, for the themes that show one."
        )
      }
      data-testid="cover-panel"
    >
      <div class="space-y-10">
        <div>
          <p class="text-token-sm font-black text-tymeslot-400 uppercase tracking-widest mb-6">
            {dgettext("dashboard_appearance", "Choose from our collection")}
          </p>
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
            <button
              :for={{id, cover} <- Cover.presets(@group)}
              type="button"
              class={[
                "group/cover relative flex flex-col rounded-token-2xl overflow-hidden border-4 transition-all duration-500",
                if(selected?(@current, id),
                  do: "border-turquoise-400 shadow-2xl shadow-turquoise-500/20 scale-[1.02]",
                  else:
                    "border-white hover:border-turquoise-200 hover:shadow-xl hover:shadow-tymeslot-200/50"
                )
              ]}
              phx-click="theme:set_option"
              phx-value-option={@group.key}
              phx-value-field="cover_value"
              phx-value-choice={id}
              phx-target={@myself}
              aria-pressed={to_string(selected?(@current, id))}
            >
              <div class="aspect-video relative overflow-hidden">
                <img
                  src={cover.thumb}
                  alt={cover.name}
                  class="w-full h-full object-cover transition-transform duration-700 group-hover/cover:scale-110"
                />
                <div
                  :if={selected?(@current, id)}
                  class="absolute top-3 right-3 w-8 h-8 bg-turquoise-500 text-white rounded-token-full flex items-center justify-center shadow-lg z-10"
                >
                  <.icon name="hero-check-mini" class="w-5 h-5" />
                </div>
              </div>
              <div class={[
                "p-5 text-left transition-colors",
                if(selected?(@current, id), do: "bg-turquoise-50", else: "bg-white")
              ]}>
                <p class="text-token-base font-black text-tymeslot-900 tracking-tight">
                  {cover.name}
                </p>
              </div>
            </button>
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
            id="theme-cover-form"
            field={:cover_path}
            uploads={@uploads}
            myself={@myself}
          />

          <div
            :if={custom?(@current)}
            class="mt-8 p-4 bg-amber-50 border border-amber-100 rounded-token-2xl flex items-center gap-4"
            data-testid="custom-cover"
          >
            <img
              src={@current.src}
              alt={dgettext("dashboard_appearance", "Your cover image")}
              class="w-32 aspect-video object-cover rounded-token-xl shrink-0"
              data-testid="custom-cover-preview"
            />
            <p class="text-token-sm font-bold text-amber-800">
              {dgettext(
                "dashboard_appearance",
                "You have a custom cover image. Selecting a preset will remove it."
              )}
            </p>
          </div>
        </div>
      </div>
    </.card>
    """
  end

  defp selected?(%{preset: preset}, id), do: preset == id
  defp selected?(nil, _id), do: false

  defp custom?(%{preset: nil}), do: true
  defp custom?(_current), do: false
end
