defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Number do
  @moduledoc "Numeric answer (HTML5 number input)."
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.TextInput

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true
  attr :autofocus, :boolean, default: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <TextInput.text_like
      input_type="number"
      definition={@definition}
      value={@value}
      myself={@myself}
      autofocus={@autofocus}
      inputmode={keypad(@definition)}
    />
    """
  end

  # An answer can be a decimal, so a bounded question asks for the decimal pad.
  # With no lower bound it can also be negative, and the phones' decimal pads
  # have no minus key, so it keeps the default number keyboard.
  defp keypad(%{"min" => min}) when not is_nil(min) do
    case Float.parse(to_string(min)) do
      {bound, _rest} when bound >= 0 -> "decimal"
      _negative_or_unparsable -> nil
    end
  end

  defp keypad(_definition), do: nil
end
