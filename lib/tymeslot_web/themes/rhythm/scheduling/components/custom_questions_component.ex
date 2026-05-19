defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.CustomQuestionsComponent do
  @moduledoc """
  Rhythm-themed renderer for the custom-questions step. One question per
  page, slide-box chrome, dots-row progress indicator (hidden when there
  is exactly one question).

  Receives the shared `Engine` state via assigns and bubbles events back
  to the parent LiveView as `{:step_event, :questions, …}`.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliser
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, Map.drop(assigns, [:flash, :socket]))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("answer", params, socket) do
    %Engine{} = engine = socket.assigns.engine
    id = Engine.current_definition(engine)["id"]
    raw = Map.get(params, "value", params)
    value = AnswerNormaliser.normalise(raw)
    send(self(), {:step_event, :questions, :answer, {id, value}})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("multi_toggle", %{"value" => key}, socket) do
    %Engine{} = engine = socket.assigns.engine
    id = Engine.current_definition(engine)["id"]
    current = Map.get(engine.answers, id) || []
    next = if key in current, do: List.delete(current, key), else: [key | current]
    send(self(), {:step_event, :questions, :answer, {id, next}})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("next", _params, socket) do
    send(self(), {:step_event, :questions, :next, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("back", _params, socket) do
    send(self(), {:step_event, :questions, :back, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    engine = assigns.engine
    d = Engine.current_definition(engine)

    assigns =
      assigns
      |> assign(:definition, d)
      |> assign(:value, Map.get(engine.answers, d["id"]))
      |> assign(:error, Map.get(engine.errors, d["id"]))
      |> assign(:index, engine.current_index)
      |> assign(:total, Engine.total(engine))
      |> assign(:last?, engine.current_index == Engine.total(engine) - 1)

    ~H"""
    <div class="scheduling-box" data-locale={@locale}>
      <div class="slide-container">
        <div class="slide active">
          <div class="slide-content">
            <%= if @total > 1 do %>
              <div
                class="rhythm-progress-dots"
                role="progressbar"
                aria-label={gettext("Question %{n} of %{m}", n: @index + 1, m: @total)}
                aria-valuenow={@index + 1}
                aria-valuemin={1}
                aria-valuemax={@total}
              >
                <%= for i <- 0..(@total - 1) do %>
                  <span
                    aria-hidden="true"
                    class={["rhythm-progress-dot", i == @index && "is-active", i < @index && "is-done"]}
                  />
                <% end %>
              </div>
            <% end %>

            <h2 class="slide-title">{@definition["label"]}</h2>

            <%= if @definition["help_text"] do %>
              <p class="rhythm-questions-help">{@definition["help_text"]}</p>
            <% end %>

            <InputRenderer.render
              definition={@definition}
              value={@value}
              myself={@myself}
            />

            <%= if @error do %>
              <p class="rhythm-form-error">{@error}</p>
            <% end %>

            <div class="slide-actions horizontal">
              <button
                type="button"
                class="prev-button"
                phx-click="back"
                phx-target={@myself}
              >
                <span class="custom-question-cta-nowrap">← {gettext("back")}</span>
              </button>

              <button
                type="button"
                class="submit-button"
                phx-click="next"
                phx-target={@myself}
              >
                <span class="custom-question-cta-nowrap">
                  <%= if @last? do %>
                    {gettext("Continue")} →
                  <% else %>
                    {gettext("next")} →
                  <% end %>
                </span>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
