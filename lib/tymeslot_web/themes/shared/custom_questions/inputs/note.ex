defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Note do
  @moduledoc """
  Acknowledgement note — renders the body text plus a single branded
  option card the booker ticks to proceed. The wire-level value is the
  token `"acknowledge"`, which `AnswerNormaliser` converts to a
  `{confirmed, confirmed_at}` map. The card's label is the `:acknowledge`
  voice line, worded by the theme `theme_key` names.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.OptionCard
  alias TymeslotWeb.Themes.Shared.Voice

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true
  attr :theme_key, :atom, default: nil, doc: "the rendering theme's catalogue key"

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    confirmed? = match?(%{"confirmed" => true}, assigns.value)
    assigns = assign(assigns, :confirmed?, confirmed?)

    ~H"""
    <div class="custom-question-note">
      <p class="custom-question-note-body">{@definition["body"]}</p>
      <div class="custom-question-option-cards">
        <OptionCard.render
          indicator={:check}
          input_type="checkbox"
          value="acknowledge"
          selected?={@confirmed?}
          event="answer"
          question={@definition["id"]}
          myself={@myself}
        >
          {acknowledgement(@theme_key)}
        </OptionCard.render>
      </div>
    </div>
    """
  end

  defp acknowledgement(theme_key) do
    Voice.line(Voice.of(theme_key), :acknowledge, %{}, fn ->
      dgettext("booking", "I acknowledge the above")
    end)
  end
end
