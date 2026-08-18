defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.EventDetailModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

  import Phoenix.LiveViewTest

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.EventDetailModal

  @integration %{
    id: 1,
    provider: :google,
    name: "Work Calendar",
    default_booking_calendar_id: nil,
    calendar_list: [
      %CalendarEntry{id: "primary", selected: true, primary: true, name: "Work"}
    ]
  }

  @event %{
    summary: "Team Standup",
    start_at: ~U[2026-04-06 08:00:00Z],
    end_at: ~U[2026-04-06 08:30:00Z],
    all_day: false,
    location: nil,
    description: nil,
    attendees: [],
    calendar_integration_id: 1,
    provider_event_id: "evt-123",
    provider_metadata: nil
  }

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        selected_event: @event,
        integrations: [@integration],
        integration_colors: %{1 => "bg-turquoise-500"},
        calendar_colors: %{},
        user_timezone: "Europe/Berlin",
        time_format: "24h",
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        editable: false,
        attendee_input: "",
        video_integrations: []
      },
      overrides
    )
  end

  test "renders event title in read-only mode" do
    html = render_component(&EventDetailModal.event_detail_modal/1, base_assigns())

    assert html =~ "Team Standup"
  end

  test "renders title input in editable mode" do
    html =
      render_component(&EventDetailModal.event_detail_modal/1, base_assigns(%{editable: true}))

    assert html =~ "event-title-input"
  end

  test "renders time range" do
    html = render_component(&EventDetailModal.event_detail_modal/1, base_assigns())

    # 08:00–08:30 UTC on 6 April 2026 is 10:00–10:30 in Europe/Berlin, which is
    # on summer time (CEST) that day.
    assert html =~ "10:00"
    assert html =~ "10:30"
    assert html =~ "CEST"
  end

  test "shows all day label for all-day events" do
    event = %{@event | all_day: true}

    html =
      render_component(
        &EventDetailModal.event_detail_modal/1,
        base_assigns(%{selected_event: event})
      )

    assert html =~ "All day"
  end

  test "renders location when present" do
    event = %{@event | location: "Conference Room A"}

    html =
      render_component(
        &EventDetailModal.event_detail_modal/1,
        base_assigns(%{selected_event: event})
      )

    assert html =~ "Conference Room A"
  end

  test "renders location as link when URL" do
    event = %{@event | location: "https://meet.google.com/abc-defg-hij"}

    html =
      render_component(
        &EventDetailModal.event_detail_modal/1,
        base_assigns(%{selected_event: event})
      )

    assert html =~ "https://meet.google.com/abc-defg-hij"
    assert html =~ "target=\"_blank\""
  end

  test "shows location input in editable mode" do
    html =
      render_component(&EventDetailModal.event_detail_modal/1, base_assigns(%{editable: true}))

    assert html =~ "Add location"
  end

  test "renders description when present" do
    event = %{@event | description: "Weekly sync meeting"}

    html =
      render_component(
        &EventDetailModal.event_detail_modal/1,
        base_assigns(%{selected_event: event})
      )

    assert html =~ "Weekly sync meeting"
  end

  test "shows description textarea in editable mode" do
    html =
      render_component(&EventDetailModal.event_detail_modal/1, base_assigns(%{editable: true}))

    assert html =~ "Add description"
  end

  test "renders attendees in read-only mode" do
    event = %{@event | attendees: [%{"name" => "Alice", "email" => "alice@example.com"}]}

    html =
      render_component(
        &EventDetailModal.event_detail_modal/1,
        base_assigns(%{selected_event: event})
      )

    assert html =~ "Alice"
    assert html =~ "alice@example.com"
  end

  test "renders attendee tags in editable mode" do
    event = %{@event | attendees: [%{"name" => "Alice", "email" => "alice@example.com"}]}
    assigns = base_assigns(%{selected_event: event, editable: true})
    html = render_component(&EventDetailModal.event_detail_modal/1, assigns)

    assert html =~ "Alice"
    assert html =~ "attendee@example.com"
  end

  test "shows delete button in editable mode" do
    html =
      render_component(&EventDetailModal.event_detail_modal/1, base_assigns(%{editable: true}))

    assert html =~ "Delete event"
  end

  test "hides delete button in read-only mode" do
    html = render_component(&EventDetailModal.event_detail_modal/1, base_assigns())

    refute html =~ "Delete event"
  end

  test "renders no-title placeholder when summary is nil" do
    event = %{@event | summary: nil}

    html =
      render_component(
        &EventDetailModal.event_detail_modal/1,
        base_assigns(%{selected_event: event})
      )

    assert html =~ "(No title)"
  end

  test "shows calendar picker in editable mode" do
    html =
      render_component(&EventDetailModal.event_detail_modal/1, base_assigns(%{editable: true}))

    assert html =~ "Work"
  end

  test "shows 'Created by Tymeslot' badge when created_by_tymeslot is true" do
    event = Map.put(@event, :created_by_tymeslot, true)

    html =
      render_component(
        &EventDetailModal.event_detail_modal/1,
        base_assigns(%{selected_event: event})
      )

    assert html =~ "Created by Tymeslot"
  end

  describe "video integration selector" do
    @video_integration %{id: 42, provider: "mirotalk", name: "Team Video"}

    test "renders selector in editable mode when video integrations are available" do
      html =
        render_component(
          &EventDetailModal.event_detail_modal/1,
          base_assigns(%{editable: true, video_integrations: [@video_integration]})
        )

      assert html =~ "Video"
      assert html =~ "Team Video"
      assert html =~ "None"
      assert html =~ "update_edit_video"
    end

    test "hides selector when no video integrations are available" do
      html =
        render_component(
          &EventDetailModal.event_detail_modal/1,
          base_assigns(%{editable: true, video_integrations: []})
        )

      refute html =~ "update_edit_video"
    end

    test "hides selector in read-only mode" do
      html =
        render_component(
          &EventDetailModal.event_detail_modal/1,
          base_assigns(%{editable: false, video_integrations: [@video_integration]})
        )

      refute html =~ "update_edit_video"
    end

    test "marks the currently selected integration as active" do
      event = Map.put(@event, :video_integration_id, 42)

      html =
        render_component(
          &EventDetailModal.event_detail_modal/1,
          base_assigns(%{
            editable: true,
            selected_event: event,
            video_integrations: [@video_integration]
          })
        )

      # The active button has the turquoise-400 border class.
      assert html =~ "border-turquoise-400"
    end
  end

  test "does not show 'Created by Tymeslot' badge when created_by_tymeslot is false" do
    event = Map.put(@event, :created_by_tymeslot, false)

    html =
      render_component(
        &EventDetailModal.event_detail_modal/1,
        base_assigns(%{selected_event: event})
      )

    refute html =~ "Created by Tymeslot"
  end
end
