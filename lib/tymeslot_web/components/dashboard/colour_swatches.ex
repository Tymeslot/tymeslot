defmodule TymeslotWeb.Components.Dashboard.ColourSwatches do
  @moduledoc """
  Palette swatch picker, shared by everything that stores an
  `Tymeslot.Integrations.Calendar.EventColour` key: a single event's colour in
  the event detail modal, a whole integration's colour in the calendar
  selection modal.

  A leading pill clears the choice (each caller names what "cleared" means to
  it — the calendar's colour for an event, the automatic rotation for an
  integration) and pushes the sentinel `"default"`; every other swatch pushes
  its palette key. Both arrive as `phx-value-colour`, so a handler always reads
  the same param.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Integrations.Calendar.EventColour

  attr :selected, :any, default: nil, doc: "the stored palette key, or nil when cleared"
  attr :event, :string, required: true, doc: "the phx-click event each swatch pushes"
  attr :target, :any, required: true
  attr :clear_label, :string, required: true, doc: "label for the pill that clears the choice"

  attr :group_label, :string,
    required: true,
    doc: "names the set for screen readers; the visible heading the caller renders above it"

  attr :values, :map,
    default: %{},
    doc: "extra phx-value-* attributes to push alongside the colour, e.g. an integration id"

  @spec colour_swatches(map()) :: Phoenix.LiveView.Rendered.t()
  def colour_swatches(assigns) do
    assigns = assign(assigns, :palette, EventColour.palette())

    ~H"""
    <div role="group" aria-label={@group_label} class="flex flex-wrap items-center gap-1.5">
      <button
        type="button"
        phx-click={@event}
        phx-value-colour="default"
        phx-target={@target}
        aria-pressed={to_string(is_nil(@selected))}
        {@values}
        class={[
          "inline-flex items-center gap-1 px-2 py-1 rounded-token-lg border text-token-xs transition-all",
          (is_nil(@selected) &&
             "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold") ||
            "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"
        ]}
      >
        {@clear_label}
      </button>
      <button
        :for={{key, label, swatch_class} <- @palette}
        type="button"
        phx-click={@event}
        phx-value-colour={key}
        phx-target={@target}
        title={label}
        aria-label={label}
        aria-pressed={to_string(@selected == key)}
        {@values}
        class={[
          "w-6 h-6 rounded-token-full ring-2 ring-offset-1 transition-all",
          swatch_class,
          (@selected == key && "ring-turquoise-500") || "ring-transparent hover:ring-tymeslot-300"
        ]}
      >
      </button>
    </div>
    """
  end
end
