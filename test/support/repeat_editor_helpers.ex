defmodule TymeslotWeb.RepeatEditorHelpers do
  @moduledoc """
  Drives the repeat editor in an event's details from a LiveView test. The
  editor stages a pattern and writes it only when it is saved, so a test
  that changes a rule saves it as the organiser would.
  """

  import Phoenix.LiveViewTest

  @doc """
  Sends the editor's fields to `element` (the grid) and saves the pattern
  they stage, answering the save's render.
  """
  @spec render_repeat_save(Phoenix.LiveViewTest.Element.t(), map()) :: String.t()
  def render_repeat_save(element, params) do
    render_hook(element, "update_event_recurrence", params)
    render_hook(element, "save_event_recurrence", %{})
  end
end
