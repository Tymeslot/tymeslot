defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.TextInput do
  @moduledoc """
  Shared HTML5 single-line input scaffold used by every text-like custom
  question type (short text, number, phone, url, date, time).

  Delegates to the application-wide `<.input>` core component so the
  custom-questions step renders inputs visually identical to the
  booking-details step. HEEx auto-escapes the `value` attribute and the
  component normalises numeric/date/time values via
  `Phoenix.HTML.Form.normalize_value/2`.

  The input is wrapped in a `<form>` so the answer commits reliably:

    * `phx-change="answer"` keeps the engine's stored answer in step with the
      field (respecting each type's own `phx-debounce`, e.g. short text debounces
      until blur).
    * `phx-submit="next"` advances on Enter. LiveView flushes any pending
      debounced change before dispatching the submit, so the value the booker
      just typed is committed *before* the wizard validates and advances.

  Without the form, the only commit was `phx-blur`, so a value typed and then
  submitted with Enter — which never blurs — was lost, advancing the wizard
  against a stale (often empty) answer.
  """
  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents

  attr :input_type, :string, required: true
  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true
  attr :rest, :global, include: ~w(autocomplete)

  @spec text_like(map()) :: Phoenix.LiveView.Rendered.t()
  def text_like(assigns) do
    ~H"""
    <form id={"cq-form-#{@definition["id"]}"} phx-change="answer" phx-submit="next" phx-target={@myself}>
      <.input
        id={"cq-input-#{@definition["id"]}"}
        type={@input_type}
        name="value"
        value={@value}
        aria-label={@definition["label"]}
        aria-required={to_string(@definition["required"] == true)}
        autofocus
        {@rest}
      />
    </form>
    """
  end
end
