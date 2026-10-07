defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.SingleSelect do
  @moduledoc """
  Single-choice answer.

  Renders as a stack of branded option cards when there are five or fewer
  options, otherwise falls back to the global `<.input type="select">` for
  compactness, inside a form: LiveView's client sends `phx-change` only from
  an input that has a form, so a bare select would never commit the answer.

  The select is `appearance-none`, so its chevron is drawn by the
  `custom-question-select` wrapper (`shared/components/custom-questions.css`).
  The wrapper holds the select alone (the input gets no label and no
  errors here), so the chevron centres on the select itself.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.OptionCard

  @radio_threshold 5

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{definition: %{"options" => options}} = assigns)
      when length(options) <= @radio_threshold do
    ~H"""
    <fieldset class="custom-question-option-cards" role="radiogroup">
      <legend class="sr-only">{@definition["label"]}</legend>
      <OptionCard.render
        :for={opt <- @definition["options"]}
        indicator={:radio}
        input_type="radio"
        value={opt["key"]}
        selected?={@value == opt["key"]}
        event="answer"
        question={@definition["id"]}
        myself={@myself}
      >
        {opt["label"]}
      </OptionCard.render>
    </fieldset>
    """
  end

  def render(assigns) do
    ~H"""
    <form
      id={"cq-form-#{@definition["id"]}"}
      phx-change="answer"
      phx-submit="next_step"
      phx-target={@myself}
      data-fact="answer"
      data-question={@definition["id"]}
    >
      <div class="custom-question-select">
        <.input
          id={"cq-input-#{@definition["id"]}"}
          type="select"
          name="value"
          value={@value}
          options={Enum.map(@definition["options"], &{&1["label"], &1["key"]})}
          prompt={dgettext("booking", "Select…")}
          aria-label={@definition["label"]}
        />
      </div>
    </form>
    """
  end
end
