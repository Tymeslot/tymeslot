defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.NoteTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Note

  defp render_input(definition, value \\ nil) do
    render_component(&Note.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders the body text and an acknowledge checkbox" do
    d = %{"type" => "note", "label" => "Terms", "body" => "Please read carefully."}
    html = render_input(d)

    assert html =~ "Please read carefully."
    assert html =~ ~s(type="checkbox")
    assert html =~ ~s(phx-value-value="acknowledge")
    assert html =~ "I acknowledge the above"
  end

  test "the checkbox is unchecked when the booker has not confirmed yet" do
    d = %{"type" => "note", "label" => "Terms", "body" => "Be nice."}

    refute render_input(d) =~ "checked"
    refute render_input(d, nil) =~ "checked"
  end

  test "the checkbox is checked once the answer carries a confirmed map" do
    d = %{"type" => "note", "label" => "Terms", "body" => "Be nice."}
    value = %{"confirmed" => true, "confirmed_at" => "2024-01-01T00:00:00Z"}

    assert render_input(d, value) =~ "checked"
  end
end
