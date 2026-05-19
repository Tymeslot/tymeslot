defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Events do
  @moduledoc """
  Theme-independent behaviour for the custom-questions LiveComponents.

  Each themed renderer (Quill, Rhythm, ...) delegates its `handle_event/3`
  callbacks here and pipes its render assigns through `assign_render_state/1`
  so the bubbling semantics and derived render assigns stay identical
  across themes.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliser
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("answer", params, socket) do
    %Engine{} = engine = socket.assigns.engine
    id = Engine.current_definition(engine)["id"]
    raw = Map.get(params, "value", params)
    value = AnswerNormaliser.normalise(raw)
    send(self(), {:step_event, :questions, :answer, {id, value}})
    {:noreply, socket}
  end

  def handle_event("multi_toggle", %{"value" => key}, socket) do
    %Engine{} = engine = socket.assigns.engine
    id = Engine.current_definition(engine)["id"]
    current = Map.get(engine.answers, id) || []
    next = if key in current, do: List.delete(current, key), else: [key | current]
    send(self(), {:step_event, :questions, :answer, {id, next}})
    {:noreply, socket}
  end

  def handle_event("next", _params, socket) do
    send(self(), {:step_event, :questions, :next, nil})
    {:noreply, socket}
  end

  def handle_event("back", _params, socket) do
    send(self(), {:step_event, :questions, :back, nil})
    {:noreply, socket}
  end

  @spec assign_render_state(Phoenix.LiveView.Socket.assigns()) ::
          Phoenix.LiveView.Socket.assigns()
  def assign_render_state(assigns) do
    engine = assigns.engine
    definition = Engine.current_definition(engine)
    total = Engine.total(engine)

    assigns
    |> assign(:definition, definition)
    |> assign(:value, Map.get(engine.answers, definition["id"]))
    |> assign(:error, Map.get(engine.errors, definition["id"]))
    |> assign(:index, engine.current_index)
    |> assign(:total, total)
    |> assign(:last?, engine.current_index == total - 1)
  end
end
