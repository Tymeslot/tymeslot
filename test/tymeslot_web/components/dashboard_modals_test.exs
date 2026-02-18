defmodule TymeslotWeb.Components.DashboardModalsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias Floki
  alias Phoenix.LiveView.JS

  alias TymeslotWeb.Components.Dashboard.Availability.ClearDayModal
  alias TymeslotWeb.Components.Dashboard.Availability.DeleteBreakModal
  alias TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal
  alias TymeslotWeb.Components.Dashboard.MeetingTypes.DeleteMeetingTypeModal

  test "renders clear_day_modal correctly" do
    assigns = %{
      id: "clear-day",
      show: true,
      day_data: %{day_number: 1, day_name: "Monday"},
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&ClearDayModal.clear_day_modal/1, assigns)

    assert html =~ "Clear Day Settings"
    assert html =~ "Monday"
    assert html =~ "Clear All Settings"
  end

  test "clear_day_modal hides when show is false" do
    assigns = %{
      id: "clear-day",
      show: false,
      day_data: %{day_number: 1, day_name: "Monday"},
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&ClearDayModal.clear_day_modal/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.attribute(doc, "div#clear-day", "style") == ["display: none;"]
  end

  test "renders delete_break_modal correctly" do
    assigns = %{
      id: "delete-break",
      show: true,
      break_data: %{day_number: 1, break_id: "break-1", info: %{label: "Lunch"}},
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&DeleteBreakModal.delete_break_modal/1, assigns)

    assert html =~ "Delete Break"
    assert html =~ "(Lunch)"
    assert html =~ "Delete Break"
  end

  test "delete_break_modal supports string-keyed break_data and label" do
    assigns = %{
      id: "delete-break",
      show: true,
      break_data: %{"day_number" => 1, "break_id" => "break-1", "info" => %{"label" => "Lunch"}},
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&DeleteBreakModal.delete_break_modal/1, assigns)

    assert html =~ "Delete Break"
    assert html =~ "(Lunch)"
  end

  test "delete_break_modal omits label when missing" do
    assigns = %{
      id: "delete-break",
      show: true,
      break_data: %{day_number: 1, break_id: "break-1", info: %{}},
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&DeleteBreakModal.delete_break_modal/1, assigns)

    assert html =~ "Delete Break"
    refute html =~ "("
    refute html =~ ")"
  end

  test "delete_break_modal omits label when whitespace-only" do
    assigns = %{
      id: "delete-break",
      show: true,
      break_data: %{day_number: 1, break_id: "break-1", info: %{label: "   "}},
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&DeleteBreakModal.delete_break_modal/1, assigns)

    assert html =~ "Delete Break"
    refute html =~ "("
    refute html =~ ")"
  end

  test "delete_break_modal normalizes whitespace within label" do
    assigns = %{
      id: "delete-break",
      show: true,
      break_data: %{day_number: 1, break_id: "break-1", info: %{label: "Lunch \n   Break"}},
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&DeleteBreakModal.delete_break_modal/1, assigns)

    assert html =~ "(Lunch Break)"
  end

  test "delete_break_modal truncates very long labels" do
    long_label = String.duplicate("a", 200)

    assigns = %{
      id: "delete-break",
      show: true,
      break_data: %{day_number: 1, break_id: "break-1", info: %{label: long_label}},
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&DeleteBreakModal.delete_break_modal/1, assigns)

    assert html =~ "(#{String.duplicate("a", 77)}...)"
  end

  test "delete_break_modal hides when show is false" do
    assigns = %{
      id: "delete-break",
      show: false,
      break_data: %{day_number: 1, break_id: "break-1", info: %{label: "Lunch"}},
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&DeleteBreakModal.delete_break_modal/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.attribute(doc, "div#delete-break", "style") == ["display: none;"]
  end

  test "renders cancel_meeting_modal correctly" do
    start_time = DateTime.utc_now(:second)
    end_time = DateTime.add(start_time, 1, :hour)

    assigns = %{
      id: "cancel-meeting",
      show: true,
      meeting: %{
        uid: "meet-123",
        attendee_name: "John Doe",
        start_time: start_time,
        end_time: end_time
      },
      cancelling: false,
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&CancelMeetingModal.cancel_meeting_modal/1, assigns)

    assert html =~ "Cancel Meeting"
    assert html =~ "John Doe"
  end

  test "cancel_meeting_modal hides when show is false" do
    start_time = DateTime.utc_now(:second)
    end_time = DateTime.add(start_time, 1, :hour)

    assigns = %{
      id: "cancel-meeting",
      show: false,
      meeting: %{
        uid: "meet-123",
        attendee_name: "John Doe",
        start_time: start_time,
        end_time: end_time
      },
      cancelling: false,
      on_cancel: %JS{},
      on_confirm: %JS{}
    }

    html = render_component(&CancelMeetingModal.cancel_meeting_modal/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.attribute(doc, "div#cancel-meeting", "style") == ["display: none;"]
  end

  test "renders delete_meeting_type_modal correctly" do
    assigns = %{
      show: true,
      meeting_type: %{id: 1, name: "Consultation"},
      myself: "some-target"
    }

    html = render_component(&DeleteMeetingTypeModal.delete_meeting_type_modal/1, assigns)

    assert html =~ "Delete Meeting Type"
    assert html =~ "Consultation"
    assert html =~ "confirm_delete_meeting_type"
  end

  test "delete_meeting_type_modal hides when meeting_type is nil" do
    assigns = %{
      show: true,
      meeting_type: nil,
      myself: "some-target"
    }

    html = render_component(&DeleteMeetingTypeModal.delete_meeting_type_modal/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.attribute(doc, "div#delete-meeting-type-modal", "style") == ["display: none;"]
  end
end
