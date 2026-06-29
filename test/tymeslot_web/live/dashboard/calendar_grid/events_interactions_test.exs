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
      assert html =~ "calendar-list-dropdown-panel"
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

  describe "event resize" do
    test "resizing an owned event is accepted and keeps the event on the grid", %{
      conn: conn,
      user: user
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)
      today = Date.utc_today()

      # Start at 06:00 UTC = 09:00 AM Europe/Tallinn (the profile-factory default).
      # The resize payload uses hour=12 in the user's local timezone; Shared.to_utc
      # converts 12:00 Tallinn (EEST, UTC+3) back to 09:00 UTC. The original end of
      # 07:00 UTC (= 10:00 AM Tallinn) becomes 09:00 UTC (= 12:00 PM Tallinn), so
      # "12:00 PM" only appears in the rendered HTML AFTER the resize is applied.
      event =
        insert_event(integration, %{
          summary: "Resizable Event",
          start_at: DateTime.new!(today, ~T[06:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[07:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # The CalendarResize hook pushes "event_resized" with the new bottom edge.
      html =
        lv
        |> element("#calendar-resize-zone")
        |> render_hook("event_resized", %{
          "event-id" => to_string(event.id),
          "event-date" => Date.to_iso8601(today),
          "new-end-hour" => "12",
          "new-end-minute" => "0"
        })

      # The optimistic update must apply without an authorization error or crash.
      refute html =~ "You don't have permission to modify this event"
      assert html =~ "Resizable Event"
      # The new 12:00 PM end edge must appear in the rendered time label —
      # this catches a regression where the resize is authorised but the
      # end time is silently not updated in the optimistic event.
      assert html =~ "12:00 PM"
    end
  end

  describe "create-event authorization" do
    # These tests exercise the save path through a real mounted LiveView so that
    # `owned_integration_ids` is populated from the DB via `load_integrations/1`
    # rather than being injected directly into a synthetic socket.
    #
    # The toolbar (and Quick-add button) only renders when the user has at least
    # one integration, so both tests insert one.  The unauthorized case then
    # swaps the in-progress `integration_id` to a fake id via render_hook so the
    # authorization gate sees an id that is not in owned_integration_ids.

    test "save_event with an owned integration passes authorization and dispatches the create",
         %{conn: conn, user: user} do
      # Inserting the integration ensures load_integrations/1 populates
      # owned_integration_ids with this id when the component mounts.
      _integration = insert(:calendar_integration, user: user, is_active: true)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # Open the create form; the component picks the first active integration
      # as the default, so creating_event.integration_id is the owned id.
      lv
      |> element("#calendar-grid-header button[phx-click='show_create_form']", "Quick add")
      |> render_click()

      # Submit the save.  The handler authorises against owned_integration_ids
      # (which came from the DB) and dispatches {:execute_create_event, ...}.
      html =
        lv
        |> element("button[phx-click='save_event']")
        |> render_click()

      # Authorization passed — no "Invalid calendar selected" error flash.
      refute html =~ "Invalid calendar selected"
    end

    test "save_event with an unowned integration yields 'Invalid calendar selected' error flash",
         %{conn: conn, user: user} do
      # One integration lets the toolbar (and Quick-add button) render while
      # keeping owned_integration_ids a singleton containing only its id.
      _integration = insert(:calendar_integration, user: user, is_active: true)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # Open the create form (integration_id defaults to the user's owned id).
      lv
      |> element("#calendar-grid-header button[phx-click='show_create_form']", "Quick add")
      |> render_click()

      # Swap the in-progress integration_id to a fake id that is not in
      # owned_integration_ids.  The #calendar-grid element carries phx-target
      # pointing at the component, so render_hook routes directly to
      # handle_event("update_create_integration", ...) on CalendarGridComponent.
      lv
      |> element("#calendar-grid")
      |> render_hook("update_create_integration", %{"integration-id" => "99999"})

      # Submit the save — auth check sees 99999 not in owned_integration_ids.
      lv
      |> element("button[phx-click='save_event']")
      |> render_click()

      # The error travels through send(self(), {:flash, ...}) → parent LiveView's
      # handle_info, so it appears after the next render cycle.
      eventually(fn ->
        assert render(lv) =~ "Invalid calendar selected"
      end)
    end
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
