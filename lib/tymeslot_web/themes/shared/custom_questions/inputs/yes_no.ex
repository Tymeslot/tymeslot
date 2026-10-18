defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.YesNo do
  @moduledoc """
  Yes / No choice. Both answers are valid.

  Rendered as a pair of tall tile-style cards (one per answer) with a
  glyph that highlights when selected. The native radio inputs are
  hidden visually but remain keyboard- and screen-reader-accessible.

  Themes style `.custom-question-yes-no*` to match their look. The two
  answers are the `:answer_yes` and `:answer_no` voice lines, worded by the
  theme `theme_key` names.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.Voice

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true
  attr :theme_key, :atom, default: nil, doc: "the rendering theme's catalogue key"

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <fieldset class="custom-question-yes-no" role="radiogroup">
      <legend class="sr-only">{@definition["label"]}</legend>

      <label class={[
        "custom-question-yes-no-tile",
        "is-yes",
        @value == true && "is-selected"
      ]}>
        <input
          type="radio"
          name={"cq-#{@definition["id"]}"}
          value="true"
          checked={@value == true}
          class="sr-only"
          phx-click="answer"
          phx-value-value="true"
          phx-value-question={@definition["id"]}
          phx-target={@myself}
          data-fact="answer"
          data-question={@definition["id"]}
          data-value="true"
        />
        <span class="custom-question-yes-no-icon" aria-hidden="true">
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <polyline points="4 12 10 18 20 6" />
          </svg>
        </span>
        <span class="custom-question-yes-no-label">{yes(@theme_key)}</span>
      </label>

      <label class={[
        "custom-question-yes-no-tile",
        "is-no",
        @value == false && "is-selected"
      ]}>
        <input
          type="radio"
          name={"cq-#{@definition["id"]}"}
          value="false"
          checked={@value == false}
          class="sr-only"
          phx-click="answer"
          phx-value-value="false"
          phx-value-question={@definition["id"]}
          phx-target={@myself}
          data-fact="answer"
          data-question={@definition["id"]}
          data-value="false"
        />
        <span class="custom-question-yes-no-icon" aria-hidden="true">
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <line x1="6" y1="6" x2="18" y2="18" />
            <line x1="18" y1="6" x2="6" y2="18" />
          </svg>
        </span>
        <span class="custom-question-yes-no-label">{no(@theme_key)}</span>
      </label>
    </fieldset>
    """
  end

  defp yes(theme_key),
    do: Voice.line(Voice.of(theme_key), :answer_yes, %{}, fn -> dgettext("booking", "Yes") end)

  defp no(theme_key),
    do: Voice.line(Voice.of(theme_key), :answer_no, %{}, fn -> dgettext("booking", "No") end)
end
