defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Ask do
  @moduledoc """
  The journey fixtures' questions moment: the meeting type's questions one at
  a time (the shared questions engine and inputs, which carry the markup
  contract's `data-fact="answer"`), with Back and Continue while it is the
  current moment. The answers are known once confirmed with Continue, so the
  moment stays current while the visitor answers. Once answered it says so
  and offers no control but, on a transcript, Edit: a page that keeps its
  moments on screen must not leave a second way on behind it.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: Events

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        answered: assigns.moment_state == :done,
        transcript: Markup.transcript?(assigns)
      )

    # The current question is read only while there is one to ask.
    assigns = if assigns.answered, do: assigns, else: Events.assign_render_state(assigns)

    Markup.moment_root(assigns, &body/1)
  end

  defp body(assigns) do
    ~H"""
    <%= if @answered do %>
      <p data-testid="journey-fixture-answers">Questions answered</p>
      <button
        :if={@transcript}
        type="button"
        phx-click="navigate_to_step"
        phx-value-step={@moment}
        data-intent="edit"
      >
        Change answers
      </button>
    <% else %>
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
      >
        {@definition["label"]}
      </JourneyComponents.moment_heading>
      <InputRenderer.render definition={@definition} value={@value} myself={@myself} />
      <p :if={@error} class="form-field__error">{@error}</p>
      <button type="button" phx-click="back_step" phx-target={@myself} data-intent="back">
        Back
      </button>
      <button type="button" phx-click="next_step" phx-target={@myself} data-intent="continue">
        Continue
      </button>
    <% end %>
    """
  end
end
