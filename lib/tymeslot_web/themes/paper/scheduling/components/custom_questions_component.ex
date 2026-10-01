defmodule TymeslotWeb.Themes.Paper.Scheduling.Components.CustomQuestionsComponent do
  @moduledoc """
  Paper's questions step: one question at a time on the card, a progress
  line and bar above it when the meeting type asks more than one, the
  shared input renderer, and Back and Next (Continue on the last one).
  Events go to the shared engine (`Shared.CustomQuestions.Events`).
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Paper.Components
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: Events

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = Events.assign_render_state(assigns)

    ~H"""
    <section class="paper-card booker-card" data-locale={@locale} data-testid="paper-questions">
      <Components.brand theme_tokens={@theme_tokens} />

      <div :if={@total > 1} class="paper-question__progress">
        <p class="paper-question__count">
          {dgettext("booking", "Question %{n} of %{m}", n: @index + 1, m: @total)}
        </p>
        <progress class="paper-question__bar" value={@index + 1} max={@total} aria-hidden="true"></progress>
      </div>

      <h1 class="paper-heading">{@definition["label"]}</h1>
      <p :if={@definition["help_text"]} class="paper-question__help">{@definition["help_text"]}</p>

      <div class={["paper-question__input", @error && "paper-question__input--invalid"]}>
        <InputRenderer.render definition={@definition} value={@value} myself={@myself} />
      </div>

      <p :if={@error} class="paper-question__error" role="alert">{@error}</p>

      <div class="paper-actions paper-actions--split">
        <button
          type="button"
          class="paper-button paper-button--quiet"
          phx-click="back_step"
          phx-target={@myself}
        >
          <.icon name="hero-arrow-left-mini" class="paper-button__icon" />
          <span class="custom-question-cta-nowrap">{dgettext("booking", "Back")}</span>
        </button>
        <button
          type="button"
          class="paper-button paper-button--primary"
          phx-click="next_step"
          phx-target={@myself}
        >
          <span class="custom-question-cta-nowrap">
            {if @last?, do: dgettext("booking", "Continue"), else: dgettext("booking", "Next")}
          </span>
          <.icon name="hero-arrow-right-mini" class="paper-button__icon" />
        </button>
      </div>
    </section>
    """
  end
end
