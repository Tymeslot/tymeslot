defmodule TymeslotWeb.Components.CoreComponents.Tooltip do
  @moduledoc """
  The one tooltip: shown on hover and keyboard focus, dismissible with Escape,
  and usable on touch. Behaviour lives in `assets/js/tooltip.js`.
  """

  use Phoenix.Component

  @doc """
  Attaches a tooltip to the control in its slot.

      <.tooltip :let={tip} id="save-tip" text={reason}>
        <button id="save" aria-describedby={tip}>Save</button>
      </.tooltip>

  The slot receives the bubble's id, which the control points at with
  `aria-describedby` so the text reaches screen readers. Pass an `id` whenever
  the text is information the control does not already say (a reason, an
  explanation); a tooltip that only repeats the control's `aria-label` can go
  without one.

  Renders a `display: contents` wrapper, so the control keeps its place in a
  flex or grid parent, with the bubble as a `popover`: it is drawn in the top
  layer, so a card's `overflow` or a modal cannot clip it.

  With a `nil`, `false` or empty `text` the wrapper stays and only the bubble
  goes, so a tooltip that comes and goes does not rebuild the control and take
  keyboard focus with it. `:none` renders the control alone: it is for
  components whose tooltip is optional and that were never given one.

  On touch, tapping a control that cannot act (`aria-disabled`, `disabled`,
  read-only, or no control at all) toggles the bubble; a control that does act
  shows it on a long press.
  """
  attr :id, :string, default: nil, doc: "id of the bubble, for `aria-describedby`"
  attr :text, :any, default: nil, doc: "the tooltip text; no bubble when nil or empty"
  slot :inner_block, required: true

  @spec tooltip(map()) :: Phoenix.LiveView.Rendered.t()
  def tooltip(%{text: :none} = assigns) do
    ~H"""
    {render_slot(@inner_block, nil)}
    """
  end

  def tooltip(%{text: text} = assigns) when text in [nil, "", false] do
    ~H"""
    <span class="tooltip-anchor" data-tooltip>{render_slot(@inner_block, nil)}</span>
    """
  end

  def tooltip(assigns) do
    ~H"""
    <span class="tooltip-anchor" data-tooltip>
      {render_slot(@inner_block, @id)}<span
        id={@id}
        role="tooltip"
        popover="manual"
        class="tooltip-bubble"
      >{@text}</span>
    </span>
    """
  end
end
