defmodule TymeslotWeb.Themes.Rhythm.Shared.MeetingTicketTest do
  use TymeslotWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component
  alias Floki
  alias TymeslotWeb.Themes.Rhythm.Shared.MeetingTicket

  describe "meeting_ticket/1" do
    test "renders meeting details with all required information" do
      assigns = %{
        header_label: "Meeting Details",
        duration_minutes: 30,
        date_value: "February 15, 2026",
        time_value: "02:00 PM",
        timezone_label: "America/New_York",
        show_organizer: false
      }

      html = render_component(&MeetingTicket.meeting_ticket/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.text(doc) =~ "Meeting Details"
      assert Floki.text(doc) =~ "30 min"
      assert Floki.text(doc) =~ "February 15, 2026"
      assert Floki.text(doc) =~ "02:00 PM"
      assert Floki.text(doc) =~ "America/New_York"
    end

    test "displays date with calendar icon" do
      assigns = %{
        header_label: "Meeting Details",
        duration_minutes: 60,
        date_value: "March 1, 2026",
        time_value: "10:00 AM",
        timezone_label: "UTC",
        show_organizer: false
      }

      html = render_component(&MeetingTicket.meeting_ticket/1, assigns)

      assert html =~ "hero-calendar"
      assert html =~ "March 1, 2026"
      assert html =~ "Date"
    end

    test "displays time with clock icon" do
      assigns = %{
        header_label: "Meeting Details",
        duration_minutes: 45,
        date_value: "April 10, 2026",
        time_value: "3:30 PM",
        timezone_label: "Europe/London",
        show_organizer: false
      }

      html = render_component(&MeetingTicket.meeting_ticket/1, assigns)

      assert html =~ "hero-clock"
      assert html =~ "3:30 PM"
      assert html =~ "Europe/London"
    end

    test "shows organizer when show_organizer is true and organizer_name is provided" do
      assigns = %{
        header_label: "Current Meeting Details",
        duration_minutes: 30,
        date_value: "May 5, 2026",
        time_value: "11:00 AM",
        timezone_label: "UTC",
        show_organizer: true,
        organizer_name: "John Doe"
      }

      html = render_component(&MeetingTicket.meeting_ticket/1, assigns)
      doc = Floki.parse_document!(html)

      assert html =~ "hero-user"
      assert Floki.text(doc) =~ "John Doe"
      assert Floki.text(doc) =~ "Meeting with"
    end

    test "hides organizer when show_organizer is false" do
      assigns = %{
        header_label: "Meeting Details",
        duration_minutes: 30,
        date_value: "June 1, 2026",
        time_value: "2:00 PM",
        timezone_label: "UTC",
        show_organizer: false,
        organizer_name: "Jane Smith"
      }

      html = render_component(&MeetingTicket.meeting_ticket/1, assigns)
      doc = Floki.parse_document!(html)

      refute Floki.text(doc) =~ "Jane Smith"
      refute Floki.text(doc) =~ "Meeting with"
    end

    test "hides organizer when organizer_name is nil even if show_organizer is true" do
      assigns = %{
        header_label: "Meeting Details",
        duration_minutes: 30,
        date_value: "July 1, 2026",
        time_value: "4:00 PM",
        timezone_label: "UTC",
        show_organizer: true,
        organizer_name: nil
      }

      html = render_component(&MeetingTicket.meeting_ticket/1, assigns)
      doc = Floki.parse_document!(html)

      refute Floki.text(doc) =~ "Meeting with"
    end

    test "renders with footer slot content when provided" do
      _assigns = %{}

      footer_slot = [
        %{
          __slot__: :footer,
          inner_block: fn assigns, _ ->
            ~H"""
            <button id="footer-action">Reschedule</button>
            """
          end
        }
      ]

      component_assigns = %{
        header_label: "Meeting Details",
        duration_minutes: 30,
        date_value: "August 1, 2026",
        time_value: "9:00 AM",
        timezone_label: "UTC",
        show_organizer: false,
        footer: footer_slot
      }

      html = render_component(&MeetingTicket.meeting_ticket/1, component_assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, "#footer-action") != []
      assert Floki.find(doc, ".ticket-footer") != []
    end

    test "does not render footer section when no footer slot provided" do
      assigns = %{
        header_label: "Meeting Details",
        duration_minutes: 30,
        date_value: "September 1, 2026",
        time_value: "1:00 PM",
        timezone_label: "UTC",
        show_organizer: false
      }

      html = render_component(&MeetingTicket.meeting_ticket/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".ticket-footer") == []
    end

    test "handles various duration values" do
      for duration <- [15, 30, 45, 60, 90, 120] do
        assigns = %{
          header_label: "Meeting Details",
          duration_minutes: duration,
          date_value: "October 1, 2026",
          time_value: "10:00 AM",
          timezone_label: "UTC",
          show_organizer: false
        }

        html = render_component(&MeetingTicket.meeting_ticket/1, assigns)
        doc = Floki.parse_document!(html)

        assert Floki.text(doc) =~ "#{duration} min"
      end
    end

    test "renders with custom header labels" do
      custom_labels = [
        "Current Meeting",
        "Upcoming Appointment",
        "Scheduled Call",
        "Meeting Information"
      ]

      for label <- custom_labels do
        assigns = %{
          header_label: label,
          duration_minutes: 30,
          date_value: "November 1, 2026",
          time_value: "3:00 PM",
          timezone_label: "UTC",
          show_organizer: false
        }

        html = render_component(&MeetingTicket.meeting_ticket/1, assigns)
        doc = Floki.parse_document!(html)

        assert Floki.text(doc) =~ label
      end
    end
  end
end
