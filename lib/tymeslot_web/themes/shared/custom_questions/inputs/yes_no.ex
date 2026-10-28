defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.YesNo do
  @moduledoc """
  Yes / No choice. Both answers are valid.

  Rendered as a pair of tall tile-style cards (one per answer) with a
  glyph that highlights when selected. The native radio inputs are
  hidden visually but remain keyboard- and screen-reader-accessible.

  Themes style `.custom-question-yes-no*` to match their look.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true

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
          name="value"
          value="true"
          checked={@value == true}
          class="sr-only"
          phx-click="answer"
          phx-value-value="true"
          phx-target={@myself}
          data-fact="answer"
          data-question={@definition["id"]}
          data-value="true"
        />
        <span class="custom-question-yes-no-icon" aria-hidden="true">
          <.icon name="hero-check" class="stroke-[2.5]" />
        </span>
        <span class="custom-question-yes-no-label">{dgettext("booking", "Yes")}</span>
      </label>

      <label class={[
        "custom-question-yes-no-tile",
        "is-no",
        @value == false && "is-selected"
      ]}>
        <input
          type="radio"
          name="value"
          value="false"
          checked={@value == false}
          class="sr-only"
          phx-click="answer"
          phx-value-value="false"
          phx-target={@myself}
          data-fact="answer"
          data-question={@definition["id"]}
          data-value="false"
        />
        <span class="custom-question-yes-no-icon" aria-hidden="true">
          <.icon name="hero-x-mark" class="stroke-[2.5]" />
        </span>
        <span class="custom-question-yes-no-label">{dgettext("booking", "No")}</span>
      </label>
    </fieldset>
    """
  end
end
