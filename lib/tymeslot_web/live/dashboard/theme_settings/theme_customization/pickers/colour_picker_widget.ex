defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColourPickerWidget do
  @moduledoc """
  Reusable on-brand HSV colour-picker widget.

  Renders a 160x160 saturation/value canvas, a horizontal hue rail, a small
  preview swatch, a hex input, and an eyedropper button. The `CustomColourPicker`
  JS hook owns its DOM after mount; this module only renders the markup.

  Pass a unique `id`, the parent LiveComponent's `target`, an `initial_hex`,
  and the `commit_event` to push back to the server when the user releases the
  pointer / commits the hex / picks via eyedropper.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :id, :string, required: true, doc: "Unique DOM id for the picker root."
  attr :target, :any, required: true, doc: "Phx target for pushEventTo (LiveComponent CID)."
  attr :initial_hex, :string, required: true, doc: "Seed colour, e.g. \"#06b6d4\"."
  attr :commit_event, :string, required: true, doc: "Event name pushed on commit."

  @spec colour_picker_widget(map()) :: Phoenix.LiveView.Rendered.t()
  def colour_picker_widget(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="CustomColourPicker"
      phx-target={@target}
      phx-update="ignore"
      data-target={@target}
      data-event={@commit_event}
      data-initial-hex={@initial_hex}
    >
      <div class="flex flex-col items-center gap-4 sm:flex-row sm:items-start">
        <div class="relative h-40 w-40 shrink-0 select-none touch-none overflow-hidden rounded-token-xl bg-white shadow-glass-sm ring-1 ring-tymeslot-200">
          <canvas
            data-cp="canvas"
            width="160"
            height="160"
            class="block h-full w-full cursor-crosshair"
          >
          </canvas>
          <div
            data-cp="canvas-thumb"
            class="pointer-events-none absolute -ml-2 -mt-2 h-4 w-4 rounded-full ring-2 ring-white shadow-md"
            style="left: 100%; top: 0%;"
          >
          </div>
        </div>

        <div class="flex flex-row items-center gap-3 sm:flex-col sm:items-stretch sm:gap-2">
          <div
            data-cp="preview"
            class="h-9 w-9 shrink-0 rounded-token-lg shadow-inner ring-1 ring-tymeslot-200"
            style={"background-color: #{@initial_hex}"}
          >
          </div>
          <input
            data-cp="hex"
            type="text"
            maxlength="7"
            autocomplete="off"
            spellcheck="false"
            aria-label={dgettext("dashboard_appearance", "Hex colour value")}
            value={String.upcase(@initial_hex)}
            class="w-28 rounded-token-lg border-2 border-tymeslot-200 bg-white px-2 py-1 font-mono text-token-2xs font-bold uppercase text-tymeslot-700 transition-all focus:border-turquoise-400 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400/20 sm:w-24"
          />
        </div>
      </div>

      <input
        data-cp="hue"
        type="range"
        min="0"
        max="360"
        step="1"
        value="0"
        aria-label={dgettext("dashboard_appearance", "Hue")}
        class="custom-colour-picker-hue mt-3 w-full"
      />
    </div>
    """
  end
end
