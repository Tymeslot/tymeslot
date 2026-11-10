defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Date do
  @moduledoc "Date answer, through the date picker."
  use Phoenix.Component

  use TymeslotWeb.Components.CoreComponents, only: [date_picker: 1]

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.TextInput

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true
  attr :autofocus, :boolean, default: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <TextInput.answer_form definition={@definition} myself={@myself}>
      <.date_picker
        id={"cq-input-#{@definition["id"]}"}
        name="value"
        value={@value}
        min={@definition["min"]}
        max={@definition["max"]}
        required={@definition["required"] == true}
        aria-label={@definition["label"]}
        autofocus={@autofocus}
      />
    </TextInput.answer_form>
    """
  end
end
