defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.MultiSelect do
  @moduledoc """
  Multiple-choice answer.

  Renders as a stack of branded option cards with checkbox semantics —
  clicking a card fires the parent `multi_toggle` event with the option
  key. The parent component is responsible for adding or removing the
  key from the current list of selected values.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.OptionCard

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    selected = assigns.value || []
    assigns = assign(assigns, :selected, selected)

    ~H"""
    <fieldset class="custom-question-option-cards">
      <legend class="sr-only">{@definition["label"]}</legend>
      <OptionCard.render
        :for={opt <- @definition["options"]}
        indicator={:check}
        input_type="checkbox"
        value={opt["key"]}
        selected?={opt["key"] in @selected}
        event="multi_toggle"
        myself={@myself}
      >
        {opt["label"]}
      </OptionCard.render>
    </fieldset>
    """
  end
end
