defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CurrentIndicator do
  @moduledoc """
  Pill component that shows the active theme selection — used by both the
  Color Palette and Solid Color sections.

  Pass one or more `swatches` (CSS `background` values: hex, rgba, gradient
  strings — anything inline-style accepts), a short `label`, an optional
  monospace `code` (e.g. the hex), and `highlighted: true` when the active
  selection is a custom value rather than a curated preset. The highlight
  swaps the muted tymeslot palette for the same turquoise treatment that
  signals "selected" elsewhere in the customisation UI.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :swatches, :list,
    required: true,
    doc: "List of CSS `background` values rendered as small dots."

  attr :label, :string, required: true
  attr :code, :string, default: nil, doc: "Optional monospace value shown after the label."

  attr :highlighted, :boolean,
    default: false,
    doc: "Turquoise treatment when the active selection is a custom value."

  @spec current_indicator(map()) :: Phoenix.LiveView.Rendered.t()
  def current_indicator(assigns) do
    ~H"""
    <div class={[
      "flex flex-wrap items-center gap-x-3 gap-y-1.5 px-3 py-2 rounded-token-2xl border shadow-inner sm:px-4",
      if(@highlighted,
        do: "bg-turquoise-50 border-turquoise-300",
        else: "bg-tymeslot-50 border-tymeslot-100"
      )
    ]}>
      <span class={[
        "text-token-2xs font-black uppercase tracking-widest",
        if(@highlighted, do: "text-turquoise-500", else: "text-tymeslot-400")
      ]}>
        {dgettext("dashboard_appearance", "Current")}
      </span>
      <div class={[
        "flex items-center gap-1.5 bg-white p-1 rounded-token-lg border",
        if(@highlighted, do: "border-turquoise-200", else: "border-tymeslot-100")
      ]}>
        <%= for swatch <- @swatches do %>
          <div class="w-3 h-3 rounded-full" style={"background: #{swatch}"}></div>
        <% end %>
      </div>
      <span class={[
        "text-token-sm font-black",
        if(@highlighted, do: "text-turquoise-700", else: "text-tymeslot-700")
      ]}>
        {@label}
      </span>
      <%= if @code do %>
        <span class={[
          "font-mono text-token-2xs font-bold",
          if(@highlighted, do: "text-turquoise-500", else: "text-tymeslot-500")
        ]}>
          {@code}
        </span>
      <% end %>
    </div>
    """
  end
end
