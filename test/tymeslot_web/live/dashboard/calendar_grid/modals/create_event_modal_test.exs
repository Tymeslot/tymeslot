defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.CreateEventModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.CreateEventModal

  @integration %{
    id: 1,
    provider: :google,
    name: "Work Calendar",
    default_booking_calendar_id: nil,
    calendar_list: [
      %CalendarEntry{id: "primary", selected: true, primary: true, name: "Work"}
    ]
  }

  @creating_event %{
    title: "Team Standup",
    all_day: false,
    date: "2026-04-06",
    end_date: "2026-04-06",
    start_hour: 9,
    start_minute: 0,
    end_hour: 9,
    end_minute: 30,
    integration_id: 1,
    calendar_id: "primary",
    attendees: [],
    attendee_input: "",
    reminders: [],
    video_integration_id: nil
  }

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        creating_event: @creating_event,
        integrations: [@integration],
        integration_colors: %{1 => "bg-turquoise-500"},
        saving: false,
        user_timezone: "Europe/Berlin",
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        video_integrations: []
      },
      overrides
    )
  end

  test "renders modal with event title" do
    html = render_component(&CreateEventModal.create_event_modal/1, base_assigns())

    assert html =~ "New Event"
    assert html =~ "Team Standup"
    assert html =~ "Create"
    assert html =~ "Cancel"
  end

  test "renders date and time inputs" do
    html = render_component(&CreateEventModal.create_event_modal/1, base_assigns())

    assert html =~ "2026-04-06"
    assert html =~ "09:00"
    assert html =~ "09:30"
  end

  test "renders an all-day toggle and time inputs when not all-day" do
    html = render_component(&CreateEventModal.create_event_modal/1, base_assigns())

    assert html =~ "All day"
    assert html =~ ~s(id="create-event-all-day")
    assert html =~ ~s(id="create-event-start-time")
    assert html =~ ~s(id="create-event-end-time")
  end

  test "hides time inputs when all-day is enabled" do
    assigns =
      base_assigns(%{creating_event: Map.put(@creating_event, :all_day, true)})

    html = render_component(&CreateEventModal.create_event_modal/1, assigns)

    assert html =~ ~s(id="create-event-start-date")
    assert html =~ ~s(id="create-event-end-date")
    refute html =~ ~s(id="create-event-start-time")
    refute html =~ ~s(id="create-event-end-time")
  end

  test "renders the reminders editor" do
    html = render_component(&CreateEventModal.create_event_modal/1, base_assigns())

    assert html =~ "Reminders"
    assert html =~ "Add reminder"
    assert html =~ ~s(phx-submit="add_create_reminder")
  end

  test "renders existing reminders" do
    assigns =
      base_assigns(%{
        creating_event:
          Map.put(@creating_event, :reminders, [%{method: :popup, minutes_before: 10}])
      })

    html = render_component(&CreateEventModal.create_event_modal/1, assigns)

    assert html =~ "Notification 10 minutes before"
  end

  test "renders attendee section" do
    html = render_component(&CreateEventModal.create_event_modal/1, base_assigns())

    assert html =~ "Invite attendees"
    assert html =~ "attendee@example.com"
  end

  test "renders existing attendees as tags" do
    assigns =
      base_assigns(%{
        creating_event:
          Map.put(@creating_event, :attendees, ["alice@example.com", "bob@example.com"])
      })

    html = render_component(&CreateEventModal.create_event_modal/1, assigns)

    assert html =~ "alice@example.com"
    assert html =~ "bob@example.com"
  end

  test "shows video integration picker when attendees present and video integrations available" do
    assigns =
      base_assigns(%{
        creating_event: Map.put(@creating_event, :attendees, ["alice@example.com"]),
        video_integrations: [%{id: 10, name: "Zoom", provider: "google_meet"}]
      })

    html = render_component(&CreateEventModal.create_event_modal/1, assigns)

    assert html =~ "Video"
    assert html =~ "Zoom"
  end

  test "hides video picker when no attendees" do
    html = render_component(&CreateEventModal.create_event_modal/1, base_assigns())

    refute html =~ "Video"
  end

  test "shows loading state when saving" do
    html = render_component(&CreateEventModal.create_event_modal/1, base_assigns(%{saving: true}))

    assert html =~ "Creating..."
  end

  test "renders calendar picker with integration" do
    html = render_component(&CreateEventModal.create_event_modal/1, base_assigns())

    assert html =~ "Work"
  end
end
