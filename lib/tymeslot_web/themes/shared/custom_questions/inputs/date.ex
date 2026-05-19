defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Date do
  @moduledoc "Date answer (HTML5 date input)."
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.TextInput

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <TextInput.text_like
      input_type="date"
      definition={@definition}
      value={@value}
      myself={@myself}
    />
    """
  end
end
