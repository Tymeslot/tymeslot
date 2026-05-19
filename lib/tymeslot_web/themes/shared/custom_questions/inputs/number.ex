defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Number do
  @moduledoc "Numeric answer (HTML5 number input)."
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.TextInput

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <TextInput.text_like
      input_type="number"
      definition={@definition}
      value={@value}
      myself={@myself}
    />
    """
  end
end
