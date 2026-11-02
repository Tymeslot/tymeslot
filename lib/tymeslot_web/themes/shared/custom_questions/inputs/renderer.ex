defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer do
  @moduledoc """
  Single entry point used by every theme to render the input
  control for a custom question (the one on show, or each of them on a
  screen that shows them all, which passes `autofocus={false}`).
  Pattern-matches on `definition["type"]` and dispatches to the
  corresponding `Inputs.*` module so each question type owns its own
  component module.

  Themes are responsible for the surrounding chrome (cards, progress,
  back/next buttons, error message). This component renders only the
  field itself. A theme with a voice passes its `theme_key`, which words
  the inputs' own lines (the select's empty choice, Yes and No, the note's
  acknowledgement); without one they keep the shared wording.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true
  attr :autofocus, :boolean, default: true

  attr :theme_key, :atom,
    default: nil,
    doc: "the rendering theme's catalogue key, whose voice words the inputs' own lines"

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{definition: %{"type" => "short_text"}} = assigns) do
    ~H"""
    <Inputs.ShortText.render
      definition={@definition}
      value={@value}
      myself={@myself}
      autofocus={@autofocus}
    />
    """
  end

  def render(%{definition: %{"type" => "number"}} = assigns) do
    ~H"""
    <Inputs.Number.render
      definition={@definition}
      value={@value}
      myself={@myself}
      autofocus={@autofocus}
    />
    """
  end

  def render(%{definition: %{"type" => "phone"}} = assigns) do
    ~H"""
    <Inputs.Phone.render
      definition={@definition}
      value={@value}
      myself={@myself}
      autofocus={@autofocus}
    />
    """
  end

  def render(%{definition: %{"type" => "url"}} = assigns) do
    ~H"""
    <Inputs.Url.render
      definition={@definition}
      value={@value}
      myself={@myself}
      autofocus={@autofocus}
    />
    """
  end

  def render(%{definition: %{"type" => "date"}} = assigns) do
    ~H"""
    <Inputs.Date.render
      definition={@definition}
      value={@value}
      myself={@myself}
      autofocus={@autofocus}
    />
    """
  end

  def render(%{definition: %{"type" => "time"}} = assigns) do
    ~H"""
    <Inputs.Time.render
      definition={@definition}
      value={@value}
      myself={@myself}
      autofocus={@autofocus}
    />
    """
  end

  def render(%{definition: %{"type" => "yes_no"}} = assigns) do
    ~H"""
    <Inputs.YesNo.render
      definition={@definition}
      value={@value}
      myself={@myself}
      theme_key={@theme_key}
    />
    """
  end

  def render(%{definition: %{"type" => "single_select"}} = assigns) do
    ~H"""
    <Inputs.SingleSelect.render
      definition={@definition}
      value={@value}
      myself={@myself}
      theme_key={@theme_key}
    />
    """
  end

  def render(%{definition: %{"type" => "multi_select"}} = assigns) do
    ~H"<Inputs.MultiSelect.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "note"}} = assigns) do
    ~H"""
    <Inputs.Note.render
      definition={@definition}
      value={@value}
      myself={@myself}
      theme_key={@theme_key}
    />
    """
  end
end
