defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.TextInput do
  @moduledoc """
  Shared HTML5 single-line input scaffold used by every text-like custom
  question type (short text, number, phone, url, date, time).

  Delegates to the application-wide `<.input>` core component so the
  custom-questions step renders inputs visually identical to the
  booking-details step. HEEx auto-escapes the `value` attribute and the
  component normalises numeric/date/time values via
  `Phoenix.HTML.Form.normalize_value/2`.
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
    <.input
      type={@input_type}
      name="value"
      value={@value}
      aria-label={@definition["label"]}
      aria-required={to_string(@definition["required"] == true)}
      phx-blur="answer"
      phx-target={@myself}
      phx-keydown="next"
      phx-key="Enter"
      autofocus
      {@rest}
    />
    """
  end
end
