defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ImageUpload do
  @moduledoc """
  The upload form for one image asset field of a theme's spec: a file input
  bound to the field's upload (declared by `AssetUploads`, named after the
  field), each entry's progress and errors, and the accepted formats. It
  sends `upload_asset` on change and on submit, with a hidden `asset_field`
  input naming the field, so the customisation component saves the file
  into it (`ThemeCustomizations.attach_asset/4`). The background's image
  picker and the logo and cover panels use it.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.Media.Uploads
  alias TymeslotWeb.Dashboard.ThemeSettings.AssetUploads

  attr :id, :string, required: true, doc: "the form's DOM id"
  attr :field, :atom, required: true, doc: "the image asset field the upload saves into"
  attr :uploads, :map, default: nil, doc: "the component's uploads, keyed by asset field"
  attr :myself, :any, required: true

  @spec image_upload(map()) :: Phoenix.LiveView.Rendered.t()
  def image_upload(assigns) do
    assigns = assign(assigns, :upload, assigns.uploads && assigns.uploads[assigns.field])

    ~H"""
    <form
      id={@id}
      phx-submit="upload_asset"
      phx-change="upload_asset"
      phx-target={@myself}
      data-auto-upload="true"
      class="flex flex-col items-center gap-6"
    >
      <input type="hidden" name="asset_field" value={@field} />
      <div class="w-full max-w-md">
        <%= if @upload do %>
          <div class="relative group/upload">
            <.live_file_input
              upload={@upload}
              class="absolute inset-0 w-full h-full opacity-0 cursor-pointer z-20"
            />
            <div class={[button_classes(:secondary), "w-full"]}>
              <.icon name="hero-arrow-up-tray" class="w-5 h-5 shrink-0 text-turquoise-600" />
              <span>{dgettext("dashboard_appearance", "Select Image")}</span>
            </div>
          </div>

          <%= for err <- upload_errors(@upload) do %>
            <div class="mt-4 p-3 bg-red-50 border border-red-100 rounded-token-xl text-red-600 text-xs font-bold flex items-center gap-2">
              <.icon name="hero-exclamation-circle" class="w-4 h-4" />
              {AssetUploads.error_message(:image, err)}
            </div>
          <% end %>

          <%= for entry <- @upload.entries do %>
            <div class="mt-6 p-4 bg-white rounded-token-2xl border-2 border-tymeslot-100 shadow-sm">
              <div class="flex items-center justify-between mb-2">
                <span class="text-tymeslot-700 font-black text-token-xs uppercase tracking-wider truncate mr-4">
                  {entry.client_name}
                </span>
                <span class="text-turquoise-600 font-black text-token-xs">{entry.progress}%</span>
              </div>
              <div class="bg-tymeslot-100 rounded-token-full h-2 overflow-hidden shadow-inner">
                <div
                  class="bg-linear-to-r from-turquoise-500 to-cyan-500 h-full transition-all duration-300"
                  style={"width: #{entry.progress}%"}
                >
                </div>
              </div>

              <%= for err <- upload_errors(@upload, entry) do %>
                <div class="mt-2 p-3 bg-red-50 border border-red-100 rounded-token-xl text-red-600 text-xs font-bold flex items-center gap-2">
                  <.icon name="hero-exclamation-circle" class="w-4 h-4" />
                  {AssetUploads.error_message(:image, err)}
                </div>
              <% end %>
            </div>
          <% end %>
        <% else %>
          <div class={[button_classes(:secondary), "w-full opacity-50"]} aria-disabled="true">
            {dgettext("dashboard_appearance", "Upload not available")}
          </div>
        <% end %>
        <button type="submit" id={"#{@id}-submit"} class="hidden">
          {dgettext("dashboard_appearance", "Upload Image")}
        </button>
      </div>

      <p class="text-token-2xs font-black text-tymeslot-400 uppercase tracking-[0.2em]">
        {dgettext(
          "dashboard_appearance",
          "JPG, PNG or WebP. Max %{size} MB and %{megapixels} megapixels (%{webp_megapixels} for WebP).",
          size: Uploads.max_file_size_mb(:image),
          megapixels: megapixel_limit(".jpg"),
          webp_megapixels: megapixel_limit(".webp")
        )}
      </p>
    </form>
    """
  end

  defp megapixel_limit(extension), do: div(ImageMetadata.pixel_limit(extension), 1_000_000)
end
