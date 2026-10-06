defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Events do
  @moduledoc """
  Theme-independent behaviour for the custom-questions LiveComponents.

  Each themed renderer (Quill, Rhythm, ...) delegates its `handle_event/3`
  callbacks here and pipes its render assigns through `assign_render_state/1`
  so the bubbling semantics and derived render assigns stay identical
  across themes.

  The events are `answer`, `multi_toggle`, `next_step` and `back_step` (the
  canonical navigation names every step uses, `Shared.StepEvents`), plus a
  theme's own `theme:<name>` events, relayed untouched; anything else is
  dropped with a warning. Events are relayed under the moment the component
  renders (`StepEvents.moment/1`), `:questions` when it has none.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliser
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.StepEvents

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("answer", params, socket) do
    %Engine{} = engine = socket.assigns.engine
    definition = Engine.current_definition(engine)
    id = definition["id"]
    raw = Map.get(params, "value", params)
    value = AnswerNormaliser.normalise(raw, definition["type"])
    send(self(), {:step_event, moment(socket), :answer, {id, value}})
    {:noreply, socket}
  end

  def handle_event("multi_toggle", %{"value" => key}, socket) do
    %Engine{} = engine = socket.assigns.engine
    id = Engine.current_definition(engine)["id"]
    current = Map.get(engine.answers, id) || []
    next = if key in current, do: List.delete(current, key), else: [key | current]
    send(self(), {:step_event, moment(socket), :answer, {id, next}})
    {:noreply, socket}
  end

  def handle_event("next_step", _params, socket) do
    send(self(), {:step_event, moment(socket), :next_step, nil})
    {:noreply, socket}
  end

  def handle_event("back_step", _params, socket) do
    send(self(), {:step_event, moment(socket), :back_step, nil})
    {:noreply, socket}
  end

  # A theme's own event, relayed untouched like `Shared.StepEvents` does.
  def handle_event("theme:" <> _name = event, params, socket) do
    send(self(), {:step_event, moment(socket), event, params})
    {:noreply, socket}
  end

  # Anything else is dropped, never raised on: a stray event must not crash
  # a public page. It leaves a warning, since it means a template sends a
  # name this step does not know.
  def handle_event(event, _params, socket) do
    StepEvents.log_ignored(socket.assigns, moment(socket), event)
    {:noreply, socket}
  end

  # The questions component's moment; `:questions`, the classic journey's,
  # when it was rendered without one.
  defp moment(socket) do
    StepEvents.moment(socket.assigns) || :questions
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
