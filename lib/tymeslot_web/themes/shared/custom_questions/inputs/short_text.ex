defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.ShortText do
  @moduledoc "Single-line free-text answer."
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.TextInput

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <TextInput.text_like
      input_type="text"
      definition={@definition}
      value={@value}
      myself={@myself}
      phx-debounce="blur"
      autocomplete="off"
    />
    """
  end
end
