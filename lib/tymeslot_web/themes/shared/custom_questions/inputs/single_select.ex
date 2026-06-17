defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.SingleSelect do
  @moduledoc """
  Single-choice answer.

  Renders as a stack of branded option cards when there are five or fewer
  options, otherwise falls back to the global `<.input type="select">`
  for compactness.
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
        myself={@myself}
      >
        {opt["label"]}
      </OptionCard.render>
    </fieldset>
    """
  end

  def render(assigns) do
    ~H"""
    <.input
      type="select"
      name="value"
      value={@value}
      options={Enum.map(@definition["options"], &{&1["label"], &1["key"]})}
      prompt={dgettext("booking", "Select…")}
      aria-label={@definition["label"]}
      phx-change="answer"
      phx-target={@myself}
    />
    """
  end
end
