defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.SingleSelect do
  @moduledoc """
  Single-choice answer.

  Renders as a stack of branded option cards when there are five or fewer
  options, otherwise falls back to the global `<.input type="select">` for
  compactness, inside a form: LiveView's client sends `phx-change` only from
  an input that has a form, so a bare select would never commit the answer.

  The select is `appearance-none`, so its arrow is the chevron icon
  `<.input>` draws over it; `shared/components/custom-questions.css`
  restyles that icon for the booking page through the
  `custom-question-select` wrapper. Its empty choice is the
  `:select_prompt` voice line, worded by the theme `theme_key` names.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.OptionCard
  alias TymeslotWeb.Themes.Shared.Voice

  @radio_threshold 5

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true
  attr :theme_key, :atom, default: nil, doc: "the rendering theme's catalogue key"

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
        name={"cq-#{@definition["id"]}"}
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
      <input type="hidden" name="question" value={@definition["id"]} />
      <div class="custom-question-select">
        <.input
          id={"cq-input-#{@definition["id"]}"}
          type="select"
          name="value"
          value={@value}
          options={Enum.map(@definition["options"], &{&1["label"], &1["key"]})}
          prompt={select_prompt(@theme_key)}
          aria-label={@definition["label"]}
        />
      </div>
    </form>
    """
  end

  defp select_prompt(theme_key) do
    Voice.line(Voice.of(theme_key), :select_prompt, %{}, fn -> dgettext("booking", "Select…") end)
  end
end
