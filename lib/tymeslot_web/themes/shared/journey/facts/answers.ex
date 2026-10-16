defmodule TymeslotWeb.Themes.Shared.Journey.Facts.Answers do
  @moduledoc """
  The answers to the organiser's questions: the meeting type's custom fields,
  held in the questions engine (`:engine`).

  Needed only when the meeting type has custom fields. It needs only the
  meeting type, so a journey may ask the questions before the calendar. Known
  once the booker has confirmed answers that validate (Continue past the last
  question), or when the meeting type has no questions; on a moment that
  also collects the attendee, once they validate (the submit confirms them).
  The wizard moves within the fact: `continue/1` stays on the questions until
  the last one validates, and `back/1` steps back until the first question,
  then leaves.
  """

  use TymeslotWeb.Themes.Shared.Journey.Fact

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine
  alias TymeslotWeb.Themes.Shared.Journey.Fact
  alias TymeslotWeb.Themes.Shared.Journey.Progress
  alias TymeslotWeb.Themes.Shared.LiveHelpers.StepEntry

  @impl Fact
  def key, do: :answers

  @impl Fact
  def requires(_assigns), do: [:meeting_type]

  @impl Fact
  def required?(assigns), do: match?(%{custom_fields: [_ | _]}, assigns[:meeting_type])

  # Known once the booker confirms the answers with Continue on the last
  # question: answers that merely validate would close the questions mid-way
  # on a page that moves on by itself (an optional question still to come, a
  # multiple choice after its first choice). Answers a reschedule carried over
  # are shown, never submitted unseen, so they also wait for the review.
  #
  # A moment that asks the questions beside the details form has no Continue
  # of its own for them: submitting the form confirms them, and the answers
  # are on screen with it, so there answers that validate are known. Read
  # here rather than confirmed in the submit, because the runtime checks the
  # form's prerequisites before the submit reaches the attendee fact.
  @impl Fact
  def known?(assigns) do
    case assigns[:engine] do
      %QEngine{} = engine ->
        QEngine.skipped?(engine) or
          ((beside_attendee?(assigns) or
              (QEngine.confirmed?(engine) and not QEngine.pending_review?(engine))) and
             match?({:ok, _answers}, QEngine.validate_all(engine)))

      _no_engine ->
        true
    end
  end

  defp beside_attendee?(%{journey: %{moments: _moments} = journey}) do
    case Progress.moment_for(journey, :answers) do
      nil -> false
      moment -> moment == Progress.moment_for(journey, :attendee)
    end
  end

  defp beside_attendee?(_assigns), do: false

  @impl Fact
  def events, do: [:answer]

  @impl Fact
  def handle(socket, :answer, {id, value}) do
    engine = QEngine.answer(socket.assigns.engine, id, value)
    {:noreply, assign(socket, :engine, engine)}
  end

  def handle(socket, :answer, _data), do: {:noreply, socket}

  @impl Fact
  def enter(socket, _params), do: StepEntry.handle_questions_entry(socket)

  # Advance within the questions wizard, or finish when all questions have
  # been answered and validated.
  #
  # Finishes only when the booker is already on the last question and
  # presses Next: this ensures a single optional question is always shown
  # before the wizard exits, even when it validates as empty.
  @impl Fact
  def continue(socket) do
    engine = socket.assigns.engine

    if QEngine.skipped?(engine) do
      {:done, socket}
    else
      last_index = QEngine.total(engine) - 1

      cond do
        engine.current_index < last_index ->
          {:stay, step_forward(socket, engine)}

        engine.current_index == last_index ->
          case QEngine.validate_all(engine) do
            {:ok, _answers} ->
              engine = engine |> QEngine.mark_reviewed() |> QEngine.confirm()
              {:done, assign(socket, :engine, engine)}

            {:error, _errors} ->
              {:stay, step_forward(socket, engine)}
          end

        true ->
          {:stay, socket}
      end
    end
  end

  # Move backwards within the wizard, or leave from the first question.
  @impl Fact
  def back(socket) do
    engine = socket.assigns.engine

    if engine.current_index == 0 do
      {:leave, socket}
    else
      {:stay, assign(socket, :engine, QEngine.prev(engine))}
    end
  end

  @impl Fact
  def clear(%{assigns: %{engine: %QEngine{definitions: definitions}}} = socket),
    do: assign(socket, :engine, QEngine.init(definitions))

  def clear(socket), do: socket

  defp step_forward(socket, engine) do
    case QEngine.next(engine) do
      {:ok, engine} -> assign(socket, :engine, engine)
      {:error, engine} -> assign(socket, :engine, engine)
    end
  end
end
