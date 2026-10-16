defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.CustomQuestionsComponent do
  @moduledoc """
  Folio's custom-questions step: the slim masthead, then one question per
  page, with "Question n of m" and a progress bar when there are several.
  The shared engine renders the input and handles its events.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Folio.Components.Masthead
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
    <section
      class="folio-card folio-card--questions booker-card"
      data-locale={@locale}
      id={assigns[:moment] && "#{assigns[:moment]}-step"}
      data-moment={assigns[:moment]}
      data-moment-state={assigns[:moment_state]}
    >
      <Masthead.masthead
        variant={:slim}
        theme_tokens={@theme_tokens}
        organizer_profile={assigns[:organizer_profile]}
        username_context={@username_context}
        meeting_label={Masthead.meeting_label(assigns)}
      />

      <div class="folio-card__body">
        <div :if={@total > 1} class="folio-progress">
          <span class="folio-eyebrow">
            {dgettext("booking", "Question %{n} of %{m}", n: @index + 1, m: @total)}
          </span>
          <span
            class="folio-progress__track"
            role="progressbar"
            aria-label={dgettext("booking", "Question %{n} of %{m}", n: @index + 1, m: @total)}
            aria-valuenow={@index + 1}
            aria-valuemin={1}
            aria-valuemax={@total}
          >
            <span class="folio-progress__bar" style={"width: #{div((@index + 1) * 100, @total)}%"}></span>
          </span>
        </div>

        <header class="folio-step-header">
          <h1 class="folio-title">{@definition["label"]}</h1>
          <p :if={@definition["help_text"]} class="folio-muted">{@definition["help_text"]}</p>
        </header>

        <div class="folio-question">
          <InputRenderer.render definition={@definition} value={@value} myself={@myself} />
          <p :if={@error} class="folio-error" role="alert">{@error}</p>
        </div>

        <div class="folio-actions">
          <button
            type="button"
            class="folio-button folio-button--quiet"
            phx-click="back_step"
            data-intent="back"
            phx-target={@myself}
          >
            <.icon name="hero-arrow-left-mini" class="folio-button__icon" />
            {dgettext("booking", "Back")}
          </button>
          <button
            type="button"
            class="folio-button folio-button--primary"
            phx-click="next_step"
            data-intent="continue"
            phx-target={@myself}
          >
            {if @last?, do: dgettext("booking", "Continue"), else: dgettext("booking", "Next")}
            <.icon name="hero-arrow-right-mini" class="folio-button__icon" />
          </button>
        </div>
      </div>
    </section>
    """
  end
end
