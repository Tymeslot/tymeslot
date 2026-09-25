defmodule TymeslotWeb.Dashboard.CalendarGrid.SeatLockedEventsTest do
  @moduledoc """
  A group booking's calendar event may not be moved from the grid.

  The provider event is a copy of the meeting, not the meeting itself:
  dragging it changes only the organiser's calendar, leaving every
  participant booked at the old time with reschedule links pointing there,
  and the next sync reports the organiser's own edit back to them as an
  external modification. The grid marks such events locked, and refuses the
  move server-side whatever the client sends.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  # The seeded event starts at 10:00 UTC and the drop asks for 14:00 in the
  # organiser's timezone; both are rendered in that timezone, so the minute
  # offsets below are what the block carries before and after a move.
  @original_start_minutes 780
  @moved_start_minutes 840

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  setup :setup_dashboard_user

  setup %{user: user} do
    {:ok, integration: insert(:calendar_integration, user: user, is_active: true)}
  end

  # A meeting plus the provider event Tymeslot wrote for it, linked by uid.
  defp booked_event(user, integration, opts) do
    today = Date.utc_today()

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        capacity: if(opts[:seats], do: 2, else: 1),
        start_time: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
        end_time: DateTime.new!(today, ~T[11:00:00], "Etc/UTC")
      )

    if opts[:seats] do
      insert(:participant, meeting: meeting)
    end

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: meeting.uid,
        summary: "Group Workshop",
        start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
        all_day: false,
        created_by_tymeslot: true
      )

    %{meeting: meeting, event: event}
  end

  defp drop_params(event) do
    %{
      "event-id" => to_string(event.id),
      "new-date" => Date.to_iso8601(Date.utc_today()),
      "new-hour" => "14",
      "new-minute" => "0",
      "new-end-hour" => "15",
      "new-end-minute" => "0"
    }
  end

  describe "a slot with live seats on it" do
    setup %{user: user, integration: integration} do
      booked_event(user, integration, seats: true)
    end

    test "renders locked, with no drag affordance and no resize handle",
         %{conn: conn, event: event} do
      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")

      block = event_block(lv, event.id)

      assert block =~ ~s(data-draggable="false")
      assert html =~ "so its time is fixed here"
      refute block =~ "data-resize-handle"
    end

    test "refuses a drop and leaves the event where it was",
         %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("event_dropped", drop_params(event))

      assert render(lv) =~ "rebook from the meeting instead"
      assert event_block(lv, event.id) =~ ~s(data-start-minutes="#{@original_start_minutes}")
    end

    test "refuses a resize", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("event_resized", %{
        "event-id" => to_string(event.id),
        "event-date" => Date.to_iso8601(Date.utc_today()),
        "new-end-hour" => "13",
        "new-end-minute" => "0"
      })

      assert render(lv) =~ "rebook from the meeting instead"
      assert event_block(lv, event.id) =~ ~s(data-duration-minutes="60")
    end

    test "refuses a time change typed into the detail modal",
         %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_time", %{
        "start-date" => Date.to_iso8601(Date.utc_today()),
        "start-time" => "14:00",
        "end-date" => Date.to_iso8601(Date.utc_today()),
        "end-time" => "15:00"
      })

      assert render(lv) =~ "rebook from the meeting instead"
      assert event_block(lv, event.id) =~ ~s(data-start-minutes="#{@original_start_minutes}")
    end

    test "the detail modal shows the time read-only", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "event-time-locked-note"
      refute html =~ ~s(id="event-time-form")
      refute html =~ ~s(id="event-all-day")
    end

    test "refuses a recurrence change typed into the detail modal",
         %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_recurrence", %{
        "freq" => "weekly",
        "interval" => "1",
        "by_day" => ["mo"],
        "end_type" => "never"
      })

      html = render(lv)
      assert html =~ "rebook from the meeting instead"
      refute html =~ "Repeats weekly"
    end

    test "the detail modal hides the recurrence editor", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      refute html =~ "Does not repeat"
    end
  end

  describe "a booking nobody holds a seat on" do
    setup %{user: user, integration: integration} do
      booked_event(user, integration, seats: false)
    end

    test "stays draggable", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      block = event_block(lv, event.id)

      assert block =~ ~s(data-draggable="true")
      assert block =~ "data-resize-handle"
    end

    test "moves when dropped", %{conn: conn, event: event} do
      # Moving a booking re-reads the host's calendar before it is written.
      Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        {:ok, []}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("event_dropped", drop_params(event))

      assert html =~ "Group Workshop"
      assert event_block(lv, event.id) =~ ~s(data-start-minutes="#{@moved_start_minutes}")
    end
  end

  # The rendered markup of one event block, so an assertion about a single
  # event cannot pass on some other element of the page.
  defp event_block(lv, event_id) do
    lv |> element("[id^='event-#{event_id}-']") |> render()
  end
end
