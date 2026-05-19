defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.OptionCard do
  @moduledoc """
  Branded answer-option card used by single-select, multi-select and the
  note acknowledgement.

  Visually consistent with the yes/no tile pair: rounded surface, accent
  fill when selected, glyph indicator on the leading edge. The native
  `<input type="radio|checkbox">` is rendered visually hidden so
  keyboard/screen-reader users get the standard semantics.
  """
  use Phoenix.Component

  attr :indicator, :atom, required: true, values: [:radio, :check]

  attr :input_type, :string,
    required: true,
    doc: "Either \"radio\" or \"checkbox\" — controls the native input element."

  attr :name, :string, default: "value"
  attr :value, :string, required: true, doc: "Option value submitted by the input."
  attr :selected?, :boolean, required: true
  attr :event, :string, required: true, doc: "Phoenix event name fired on click."
  attr :myself, :any, required: true

  slot :inner_block, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <label class={[
      "custom-question-option-card",
      @selected? && "is-selected"
    ]}>
      <input
        type={@input_type}
        name={@name}
        value={@value}
        checked={@selected?}
        class="sr-only"
        phx-click={@event}
        phx-value-value={@value}
        phx-target={@myself}
      />
      <span
        class={["custom-question-option-indicator", "is-#{@indicator}"]}
        aria-hidden="true"
      >
        <svg :if={@indicator == :check} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="4 12 10 18 20 6" />
        </svg>
      </span>
      <span class="custom-question-option-label">{render_slot(@inner_block)}</span>
    </label>
    """
  end
end
