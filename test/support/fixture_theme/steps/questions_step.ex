defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.QuestionsStep do
  @moduledoc """
  The fixture theme's custom-questions step: the current question through
  the shared inputs (`CustomQuestions.Inputs.Renderer`), its error, and the
  ways back and on, unstyled.
  """
  use TymeslotWeb, :live_component

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
    <section class="booker-card" data-testid="fixture-questions">
      <h2>{@definition["label"]}</h2>
      <InputRenderer.render definition={@definition} value={@value} myself={@myself} />
      <p :if={@error} data-testid="fixture-question-error">{@error}</p>
      <button type="button" phx-click="back_step" phx-target={@myself} data-intent="back">
        Back
      </button>
      <button type="button" phx-click="next_step" phx-target={@myself} data-intent="continue">
        Next
      </button>
    </section>
    """
  end
end
