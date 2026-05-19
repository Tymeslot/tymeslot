defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent do
  @moduledoc """
  Quill-themed renderer for the custom-questions step. One question per
  page, glassmorphism card chrome, numeric "N of M" progress indicator
  (hidden when there is exactly one question).

  Receives the shared `Engine` state via assigns and bubbles events back
  to the parent LiveView as `{:step_event, :questions, …}`.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents

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
    <div class="container flex-1" data-locale={@locale}>
      <.page_layout show_steps={true} current_step={3} slug={@duration} username_context={@username_context}>
        <div class="stack">
          <div class="flex-1 flex items-center justify-center px-4 py-4">
            <div class="w-full max-w-2xl">
              <.glass_morphism_card class="custom-questions-card">
                <div class="booking-card-body">
                  <%= if @total > 1 do %>
                    <p class="text-quill-secondary text-sm mb-2 custom-questions-progress">
                      {gettext("Question %{n} of %{m}", n: @index + 1, m: @total)}
                    </p>
                  <% end %>

                  <.section_header
                    level={2}
                    class="booking-heading-wrapper"
                    title_class="section-header booking-heading"
                  >
                    {@definition["label"]}
                  </.section_header>

                  <%= if @definition["help_text"] do %>
                    <p class="text-quill-secondary mb-2">{@definition["help_text"]}</p>
                  <% end %>

                  <InputRenderer.render
                    definition={@definition}
                    value={@value}
                    myself={@myself}
                  />

                  <%= if @error do %>
                    <p class="form-field__error">{@error}</p>
                  <% end %>

                  <div class="booking-actions">
                    <.action_button
                      type="button"
                      phx-click="back"
                      phx-target={@myself}
                      variant={:secondary}
                      class="flex-1"
                    >
                      <span class="custom-question-cta-nowrap">← {gettext("back")}</span>
                    </.action_button>

                    <.action_button
                      type="button"
                      phx-click="next"
                      phx-target={@myself}
                      class="flex-1"
                    >
                      <span class="custom-question-cta-nowrap">
                        <%= if @last? do %>
                          {gettext("Continue")} →
                        <% else %>
                          {gettext("next")} →
                        <% end %>
                      </span>
                    </.action_button>
                  </div>
                </div>
              </.glass_morphism_card>
            </div>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end
end
