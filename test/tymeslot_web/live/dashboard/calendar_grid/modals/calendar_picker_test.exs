defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.CalendarPickerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.CalendarPicker

  @integration %{
    id: 1,
    provider: :google,
    name: "Work Calendar",
    default_booking_calendar_id: nil,
    calendar_list: [
      %{
        "id" => "primary@gmail.com",
        "selected" => true,
        "primary" => true,
        "summary" => "Primary"
      },
      %{
        "id" => "meetings@gmail.com",
        "selected" => true,
        "primary" => false,
        "summary" => "Meetings"
      }
    ]
  }

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        integrations: [@integration],
        integration_colors: %{1 => "bg-turquoise-500"},
        selected_integration_id: 1,
        selected_calendar_id: "primary@gmail.com",
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        event_name: "update_calendar"
      },
      overrides
    )
  end

  test "renders integration name and calendars" do
    html = render_component(&CalendarPicker.calendar_picker/1, base_assigns())

    assert html =~ "Work Calendar"
    assert html =~ "primary@gmail.com"
    assert html =~ "meetings@gmail.com"
  end

  test "highlights selected calendar" do
    html = render_component(&CalendarPicker.calendar_picker/1, base_assigns())

    # The selected calendar should have the turquoise styling
    assert html =~ "border-turquoise-400"
  end

  test "renders default calendar button when no calendar list" do
    integration = %{@integration | calendar_list: []}

    html =
      render_component(
        &CalendarPicker.calendar_picker/1,
        base_assigns(%{integrations: [integration]})
      )

    assert html =~ "Default calendar"
  end

  test "renders multiple integrations" do
    second = %{
      id: 2,
      provider: :caldav,
      name: "Personal CalDAV",
      calendar_list: [%{"id" => "personal", "selected" => true, "summary" => "Personal"}]
    }

    html =
      render_component(
        &CalendarPicker.calendar_picker/1,
        base_assigns(%{integrations: [@integration, second]})
      )

    assert html =~ "Work Calendar"
    assert html =~ "Personal CalDAV"
  end

  describe "derive_event_calendar_id/2" do
    test "returns nil when integration is nil" do
      assert CalendarPicker.derive_event_calendar_id(%{}, nil) == nil
    end

    test "derives Google calendar ID from organizer email" do
      event = %{
        provider_metadata: %{"organizer" => %{"email" => "meetings@gmail.com"}},
        provider_event_id: nil
      }

      assert CalendarPicker.derive_event_calendar_id(event, @integration) == "meetings@gmail.com"
    end

    test "derives CalDAV calendar ID from provider_event_id path" do
      integration = %{
        id: 1,
        calendar_list: [
          %{"id" => "/caldav/personal/", "path" => "/caldav/personal/", "selected" => true}
        ],
        default_booking_calendar_id: nil
      }

      event = %{provider_metadata: nil, provider_event_id: "/caldav/personal/event-123.ics"}
      assert CalendarPicker.derive_event_calendar_id(event, integration) == "/caldav/personal/"
    end

    test "falls back to default when no match" do
      event = %{provider_metadata: nil, provider_event_id: nil}
      result = CalendarPicker.derive_event_calendar_id(event, @integration)

      assert result == "primary@gmail.com"
    end
  end
end
