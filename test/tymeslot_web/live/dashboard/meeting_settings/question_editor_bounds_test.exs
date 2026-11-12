defmodule TymeslotWeb.Dashboard.MeetingSettings.QuestionEditorBoundsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :meeting_types

  import Phoenix.LiveViewTest

  alias Tymeslot.CustomFields.FieldDefinition
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.QuestionEditorComponent

  defp render_editor(type) do
    render_component(QuestionEditorComponent,
      id: "question-editor",
      form_id: "question-editor",
      definition: %FieldDefinition{type: type},
      existing_fields: []
    )
  end

  test "a date question's limits are date pickers, posting definition[min] and [max]" do
    html = render_editor("date")

    assert html =~ ~s(phx-hook="DateTimePicker")
    assert html =~ ~s(name="definition[min]")
    assert html =~ ~s(name="definition[max]")
    assert html =~ ~s(id="definition_min-native" data-picker-native type="date")
  end

  test "a time question's limits are time pickers" do
    assert render_editor("time") =~ ~s(type="time")
  end

  test "a number question's limits stay number fields" do
    html = render_editor("number")

    assert html =~ ~s(type="number")
    refute html =~ ~s(phx-hook="DateTimePicker")
  end
end
