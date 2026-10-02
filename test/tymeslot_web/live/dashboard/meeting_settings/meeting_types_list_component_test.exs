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
        %{
          meeting_types: [],
          show_add_form: false,
          editing_type: nil,
          parent_myself: %Phoenix.LiveComponent.CID{cid: 1}
        },
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

  describe "meeting_types_section/1 with meeting types listed" do
    test "offers Add Meeting Type once, in the header, with no empty state" do
      type = %{
        id: 1,
        name: "Strategy Call",
        description: nil,
        duration_minutes: 30,
        icon: "hero-bolt",
        is_active: true,
        is_private: false,
        allow_video: false,
        payment_required: false,
        price_cents: nil,
        custom_fields: [],
        video_integration: nil,
        calendar_integration: nil,
        target_calendar_id: nil
      }

      doc = render_section(%{meeting_types: [type]})

      assert Enum.count(add_buttons(doc)) == 1
      assert LazyHTML.text(doc) =~ "Strategy Call"
      refute LazyHTML.text(doc) =~ "No meeting types configured yet"

      assert doc
             |> LazyHTML.query(".card-glass button[phx-click='toggle_add_form']")
             |> Enum.empty?()
    end
  end
end
