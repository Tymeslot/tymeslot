defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer do
  @moduledoc """
  Single entry point used by both Quill and Rhythm to render the input
  control for the currently-displayed custom question. Pattern-matches on
  `definition["type"]` and dispatches to the corresponding `Inputs.*`
  module so each question type owns its own component module.

  Themes are responsible for the surrounding chrome (cards, progress,
  back/next buttons, error message). This component renders only the
  field itself.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{definition: %{"type" => "short_text"}} = assigns) do
    ~H"<Inputs.ShortText.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "number"}} = assigns) do
    ~H"<Inputs.Number.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "phone"}} = assigns) do
    ~H"<Inputs.Phone.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "url"}} = assigns) do
    ~H"<Inputs.Url.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "date"}} = assigns) do
    ~H"<Inputs.Date.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "time"}} = assigns) do
    ~H"<Inputs.Time.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "yes_no"}} = assigns) do
    ~H"<Inputs.YesNo.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "single_select"}} = assigns) do
    ~H"<Inputs.SingleSelect.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "multi_select"}} = assigns) do
    ~H"<Inputs.MultiSelect.render definition={@definition} value={@value} myself={@myself} />"
  end

  def render(%{definition: %{"type" => "note"}} = assigns) do
    ~H"<Inputs.Note.render definition={@definition} value={@value} myself={@myself} />"
  end
end
