defmodule TymeslotWeb.Components.Dashboard.ColourSwatches do
  @moduledoc """
  Palette swatch picker, shared by everything that stores an
  `Tymeslot.Integrations.Calendar.EventColour` key: a single event's colour in
  the event detail modal, a whole integration's colour in the calendar
  selection modal.

  A trailing swatch clears the choice and pushes the sentinel `"default"`;
  every other swatch pushes its palette key. Both arrive as `phx-value-colour`,
  so a handler always reads the same param.

  The clearing swatch is shaped and sized like the colours it sits beside, and
  comes last, so every picker in the app lines up on one grid however many of
  them are stacked. It carries one shared label rather than a per-caller one:
  what it inherits from differs by caller (an event falls back to its calendar,
  a calendar to its account), but naming the mechanism asked the reader to hold
  that hierarchy in their head. Naming the action does not, and saying it the
  same way everywhere is worth more than describing each case precisely.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.EventColour

  attr :selected, :any, default: nil, doc: "the stored palette key, or nil when cleared"
  attr :event, :string, required: true, doc: "the phx-click event each swatch pushes"
  attr :target, :any, required: true

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
      ></button>
      <button
        type="button"
        phx-click={@event}
        phx-value-colour="default"
        phx-target={@target}
        title={clear_label()}
        aria-label={clear_label()}
        aria-pressed={to_string(is_nil(@selected))}
        {@values}
        class={[
          "w-6 h-6 rounded-token-full ring-2 ring-offset-1 transition-all",
          "inline-flex items-center justify-center border border-tymeslot-300 bg-white",
          (is_nil(@selected) && "ring-turquoise-500 text-turquoise-700") ||
            "ring-transparent text-tymeslot-500 hover:ring-tymeslot-300"
        ]}
      >
        <.icon name="hero-no-symbol-micro" class="w-3.5 h-3.5" />
      </button>
    </div>
    """
  end

  # The swatch carries no visible text, so this is its only name — for a screen
  # reader and for the tooltip alike.
  defp clear_label, do: dgettext("dashboard_calendar", "Default colour")
end
