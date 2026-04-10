defmodule TymeslotWeb.Dashboard.CalendarGrid.EventsInteractionsTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "recurring event prompt" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Recurring Meeting",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false,
          recurring_event_id: "master-event-123"
        })

      {:ok, event: event}
    end

    test "shows scope dialog when dropping a recurring event", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      tomorrow_iso = Date.to_iso8601(Date.add(Date.utc_today(), 1))

      html =
        lv
        |> element("#calendar-drag-zone")
        |> render_hook("event_dropped", %{
          "event-id" => to_string(event.id),
          "new-date" => tomorrow_iso,
          "new-hour" => "10",
          "new-minute" => "0",
          "new-end-hour" => "11",
          "new-end-minute" => "0"
        })

      assert html =~ "Edit recurring event"
    end

    test "cancel recurrence prompt reverts event and dismisses dialog", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Recurring Meeting"

      tomorrow_iso = Date.to_iso8601(Date.add(Date.utc_today(), 1))

      lv
      |> element("#calendar-drag-zone")
      |> render_hook("event_dropped", %{
        "event-id" => to_string(event.id),
        "new-date" => tomorrow_iso,
        "new-hour" => "10",
        "new-minute" => "0",
        "new-end-hour" => "11",
        "new-end-minute" => "0"
      })

      html =
        lv |> element("#recurrence-prompt-modal button", "Cancel") |> render_click()

      refute html =~ "Edit recurring event"
      # Event is still rendered after revert
      assert html =~ "Recurring Meeting"
    end

    test "confirm 'this_only' scope dismisses the prompt", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      tomorrow_iso = Date.to_iso8601(Date.add(Date.utc_today(), 1))

      lv
      |> element("#calendar-drag-zone")
      |> render_hook("event_dropped", %{
        "event-id" => to_string(event.id),
        "new-date" => tomorrow_iso,
        "new-hour" => "10",
        "new-minute" => "0",
        "new-end-hour" => "11",
        "new-end-minute" => "0"
      })

      html =
        lv
        |> element("[phx-click='confirm_recurrence_scope'][phx-value-scope='this_only']")
        |> render_click()

      refute html =~ "Edit recurring event"
    end
  end

  describe "calendar visibility toggles" do
    test "shows calendar list panel on Calendars button click", %{conn: conn, user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("button", "Calendars") |> render_click()
      assert html =~ "calendar-list-panel"
    end

    test "hides events when integration is toggled off", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        summary: "Hidden Event",
        start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Hidden Event"

      # Open calendar list panel first so the toggle element is rendered
      lv |> element("button", "Calendars") |> render_click()

      html =
        lv
        |> element(
          "[phx-click='toggle_integration_visibility'][phx-value-integration-id='#{integration.id}']"
        )
        |> render_click()

      refute html =~ "Hidden Event"
    end
  end

  describe "drag-and-drop authorization" do
    test "drop event from owned integration is accepted", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Moveable Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      tomorrow_iso = Date.to_iso8601(Date.add(Date.utc_today(), 1))

      # Route the hook event to the component via the CalendarDrag hook element
      html =
        lv
        |> element("#calendar-drag-zone")
        |> render_hook("event_dropped", %{
          "event-id" => to_string(event.id),
          "new-date" => tomorrow_iso,
          "new-hour" => "10",
          "new-minute" => "0",
          "new-end-hour" => "11",
          "new-end-minute" => "0"
        })

      refute html =~ "You don't have permission to modify this event"
    end
  end

  describe "all-day event move" do
    test "moving an all-day event to another integration does not crash", %{
      conn: conn,
      user: user
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)
      other_integration = insert(:calendar_integration, user: user, is_active: true)
      today = Date.utc_today()

      event =
        insert_event(integration, %{
          summary: "All Day Conf",
          all_day: true,
          start_date: today,
          end_date: Date.add(today, 1),
          start_at: nil,
          end_at: nil
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # All-day events are in the banner row, not the time grid; open via the show_event hook
      lv
      |> element("#calendar-grid")
      |> render_hook("show_event", %{"event-id" => to_string(event.id)})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_calendar", %{
          "integration-id" => to_string(other_integration.id)
        })

      # The optimistic UI update must not raise; no permission error expected
      refute html =~ "You don't have permission"
    end
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
