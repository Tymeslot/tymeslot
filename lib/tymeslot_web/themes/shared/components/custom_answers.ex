defmodule TymeslotWeb.Themes.Shared.Components.CustomAnswers do
  @moduledoc """
  The confirmation step's "Your answers" list: each custom question from the
  booking's snapshot with the guest's answer, rendered through
  `Tymeslot.CustomFields.AnswerRenderer`.

  Fixed markup with `custom-answers__*` class names; each theme styles them in
  its own CSS. A question whose answer renders empty (one left blank, or a
  note the guest did not tick) gets no row, as on the dashboard and in the
  emails, and the section renders nothing when no row is left, including
  when the meeting type asked no questions. A time answer reads on the
  visitor's clock, as the meeting's own time above it does.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :snapshot, :list, default: nil, doc: "the booking's `custom_fields_snapshot`"
  attr :answers, :map, default: nil, doc: "answers keyed by question id"

  @spec custom_answers(map()) :: Phoenix.LiveView.Rendered.t()
  def custom_answers(assigns) do
    assigns = assign(assigns, :rows, rows(assigns.snapshot, assigns.answers || %{}))

    ~H"""
    <section :if={@rows != []} class="custom-answers">
      <h3 class="custom-answers__heading">{dgettext("booking", "Your answers")}</h3>
      <dl class="custom-answers__list">
        <div :for={{question, rendered} <- @rows} class="custom-answers__row">
          <dt class="custom-answers__label">{question["label"]}</dt>
          <dd class="custom-answers__value">{rendered}</dd>
        </div>
      </dl>
    </section>
    """
  end

  defp rows(nil, _answers), do: []

  defp rows(snapshot, answers) do
    snapshot
    |> Enum.map(&{&1, render_answer(&1, answers[&1["id"]])})
    |> Enum.reject(fn {_question, rendered} -> rendered == "" end)
  end

  defp render_answer(%{"type" => "time"}, answer) when is_binary(answer) and answer != "",
    do: LocalizationHelpers.format_slot_label(answer)

  defp render_answer(question, answer), do: AnswerRenderer.render(question, answer)
end
