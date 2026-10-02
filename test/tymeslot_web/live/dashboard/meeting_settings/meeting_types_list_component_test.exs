defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypesListComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :meeting_types

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypesListComponent

  defp render_section(overrides) do
    MeetingTypesListComponent
    |> Function.capture(:meeting_types_section, 1)
    |> render_component(
      Map.merge(
        %{meeting_types: [], show_add_form: false, editing_type: nil, parent_myself: nil},
        overrides
      )
    )
    |> LazyHTML.from_fragment()
  end

  defp add_buttons(doc), do: LazyHTML.query(doc, "button[phx-click='toggle_add_form']")

  describe "meeting_types_section/1 with no meeting types" do
    test "offers Add Meeting Type once, inside the empty state" do
      doc = render_section(%{})

      assert Enum.count(add_buttons(doc)) == 1

      assert doc
             |> LazyHTML.query(".card-glass button[phx-click='toggle_add_form']")
             |> Enum.count() == 1

      assert LazyHTML.text(doc) =~ "No meeting types configured yet"
    end

    test "offers no add button while a meeting type is being edited" do
      doc = render_section(%{editing_type: %{id: 1}})

      assert Enum.empty?(add_buttons(doc))
    end
  end
end
