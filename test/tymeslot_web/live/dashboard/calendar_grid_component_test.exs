defmodule TymeslotWeb.Dashboard.CalendarGridComponentTest do
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

  describe "navigation" do
    test "renders calendar grid page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Calendar"
    end

    test "shows current week period label containing the current year", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ to_string(Date.utc_today().year)
    end
  end

  describe "view switching" do
    test "switches to day view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("button", "Day") |> render_click()
      assert html =~ Calendar.strftime(Date.utc_today(), "%A")
    end

    test "switches back to week view after day view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button", "Day") |> render_click()
      html = lv |> element("button", "Week") |> render_click()
      # Week view shows short day names, not the full "DayName, Month Day, Year" format
      refute html =~ Calendar.strftime(Date.utc_today(), "%A, %B %-d, %Y")
    end
  end

  describe "date navigation" do
    test "navigates to next week and changes period label", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      original_label = extract_period_label(html)
      new_html = lv |> element("button[aria-label='Next period']") |> render_click()
      refute extract_period_label(new_html) == original_label
    end

    test "navigates to previous week and changes period label", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      original_label = extract_period_label(html)
      new_html = lv |> element("button[aria-label='Previous period']") |> render_click()
      refute extract_period_label(new_html) == original_label
    end

    test "today button returns to current week", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      original_label = extract_period_label(html)
      lv |> element("button[aria-label='Next period']") |> render_click()
      returned_html = lv |> element("button", "Today") |> render_click()
      assert extract_period_label(returned_html) == original_label
    end
  end

  describe "events" do
    test "renders event title in grid", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        title: "My Test Meeting",
        start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "My Test Meeting"
    end

    test "all-day event appears in banner row", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        title: "All Day Conference",
        start_at: DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.add(Date.utc_today(), 1), ~T[00:00:00], "Etc/UTC"),
        all_day: true
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "All Day Conference"
      assert html =~ "calendar-allday-row"
    end

    test "opens event detail modal on click", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Clickable Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()
      # Modal appears with event title and time range
      assert html =~ "Clickable Event"
      assert html =~ "2:00 PM" or html =~ "14:00"
    end

    test "event detail modal shows location", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Off-site Meetup",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false,
          location: "Downtown Conference Center"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()
      assert html =~ "Downtown Conference Center"
    end

    test "event detail modal shows description (notes)", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Planning Session",
          start_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[12:00:00], "Etc/UTC"),
          all_day: false,
          description: "Discuss Q2 roadmap and priorities"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()
      assert html =~ "Discuss Q2 roadmap and priorities"
    end

    test "event detail modal shows attendee names", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Team Sync",
          start_at: DateTime.new!(Date.utc_today(), ~T[13:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [
            %{"email" => "alice@example.com", "name" => "Alice Smith", "status" => "accepted"},
            %{"email" => "bob@example.com", "name" => "Bob Jones", "status" => "tentative"}
          ]
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()
      assert html =~ "Alice Smith"
      assert html =~ "Bob Jones"
    end

    test "event detail modal falls back to attendee email when name is absent", %{
      conn: conn,
      user: user
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Anonymous Meeting",
          start_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[16:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [
            %{"email" => "unknown@example.com", "name" => nil, "status" => nil}
          ]
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()
      assert html =~ "unknown@example.com"
    end

    test "closes event detail modal after opening it", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Close Me",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      # Dismiss via the close_event_detail event rather than targeting a specific button
      lv |> element("#calendar-grid") |> render_hook("close_event_detail", %{})
      html = render(lv)
      refute html =~ "modal-overlay"
    end
  end

  describe "refresh" do
    test "shows refresh button", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Refresh"
    end
  end

  describe "month view" do
    test "renders month grid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("button", "Month") |> render_click()
      assert html =~ "calendar-month-grid"
      assert html =~ to_string(Date.utc_today().year)
    end

    test "clicking a day cell navigates to day view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button", "Month") |> render_click()
      today_iso = Date.to_iso8601(Date.utc_today())

      html =
        lv
        |> element("[phx-click='navigate_to_day'][phx-value-date='#{today_iso}']")
        |> render_click()

      assert html =~ Calendar.strftime(Date.utc_today(), "%A, %B")
    end
  end

  describe "recurring event prompt" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Recurring Meeting",
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
        title: "Hidden Event",
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

  describe "event creation form" do
    test "shows create form on show_create_form hook event", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today_iso = Date.to_iso8601(Date.utc_today())

      # Route the hook event to the component via the CalendarCreate hook element
      html =
        lv
        |> element("#calendar-create-zone")
        |> render_hook("show_create_form", %{
          "date" => today_iso,
          "start-hour" => "10",
          "start-minute" => "0",
          "end-hour" => "11",
          "end-minute" => "0"
        })

      assert html =~ "New Event"
    end

    test "closes create form on close_create_form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today_iso = Date.to_iso8601(Date.utc_today())

      lv
      |> element("#calendar-create-zone")
      |> render_hook("show_create_form", %{
        "date" => today_iso,
        "start-hour" => "10",
        "start-minute" => "0",
        "end-hour" => "11",
        "end-minute" => "0"
      })

      html = lv |> element("#create-event-modal button", "Cancel") |> render_click()
      refute html =~ "New Event"
    end
  end

  describe "PubSub live updates" do
    test "re-renders events when :calendar_events_updated is broadcast", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        title: "Live Update Event",
        start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Live Update Event"

      insert_event(integration, %{
        title: "New Live Event",
        start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
        all_day: false
      })

      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        "calendar_events:#{user.id}",
        {:calendar_events_updated, user.id, []}
      )

      assert render(lv) =~ "New Live Event"
    end
  end

  describe "swipe navigation" do
    test "navigate_swipe 'next' advances to next day", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button", "Day") |> render_click()
      html = render(lv)
      original_label = extract_period_label(html)

      lv
      |> element("#calendar-grid")
      |> render_hook("navigate_swipe", %{"direction" => "next"})

      new_label = extract_period_label(render(lv))
      refute new_label == original_label
    end

    test "navigate_swipe 'prev' goes back one day", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button", "Day") |> render_click()
      html = render(lv)
      original_label = extract_period_label(html)

      lv
      |> element("#calendar-grid")
      |> render_hook("navigate_swipe", %{"direction" => "prev"})

      new_label = extract_period_label(render(lv))
      refute new_label == original_label
    end
  end

  describe "async event update failure" do
    test "reverts event and shows error flash when update fails", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Failing Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Failing Event"

      # Simulate the async error result message arriving at the LiveView
      send(lv.pid, {:event_update_result, {:error, original_event: event, reason: :api_error}})

      html = render(lv)
      assert html =~ "Failed to update event"
      assert html =~ "Failing Event"
    end
  end

  describe "drag-and-drop authorization" do
    test "drop event from owned integration is accepted", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Moveable Event",
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

  describe "graceful rendering of sparse event data" do
    test "renders events with nil title gracefully", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        title: nil,
        start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      # Page renders without crashing — the event slot is present in the grid
      assert html =~ "calendar"
    end

    test "renders events with nil description gracefully", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "No Description Event",
          description: nil,
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      # Open the event detail modal — nil description must not crash
      html = lv |> element("#event-#{event.id}") |> render_click()
      assert html =~ "No Description Event"
    end

    test "renders events with empty attendees", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Solo Meeting",
          start_at: DateTime.new!(Date.utc_today(), ~T[16:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[17:00:00], "Etc/UTC"),
          all_day: false,
          attendees: []
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      # Open the event detail modal — empty attendees list must not crash
      html = lv |> element("#event-#{event.id}") |> render_click()
      assert html =~ "Solo Meeting"
    end
  end

  describe "inline title editing" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      today = Date.utc_today()

      event =
        insert_event(integration, %{
          title: "Team Standup",
          start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, event: event}
    end

    test "shows editable title input for owned events", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()

      assert html =~ "event-title-input"
      assert html =~ ~s(name="value")
      assert html =~ "Team Standup"
    end

    test "saves title on blur", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_title", %{"value" => "Renamed Standup"})

      assert html =~ "Renamed Standup"
    end

    test "does not save when title is unchanged", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_title", %{"value" => "Team Standup"})

      refute html =~ "error"
      assert html =~ "Team Standup"
    end

    test "sanitises malicious input in title", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_title", %{"value" => "<script>alert('xss')</script>"})

      refute html =~ "<script>"
      assert html =~ "alert"
    end

    test "rejects title exceeding max length", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      long_title = String.duplicate("a", 501)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => long_title})

      assert render(lv) =~ "Input too long"
    end
  end

  describe "inline location editing" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Location Event",
          location: "Room 101",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, event: event}
    end

    test "shows editable location input for owned events", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()

      assert html =~ "event-location-input"
      assert html =~ "Room 101"
    end

    test "saves location on blur", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_location", %{"value" => "Room 202"})

      assert html =~ "Room 202"
    end

    test "does not save when location is unchanged", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_location", %{"value" => "Room 101"})

      assert html =~ "Room 101"
    end

    test "shows placeholder when event has no location", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "No Location Event",
          location: nil,
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()

      assert html =~ "Add location"
    end

    test "rejects location exceeding max length", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      long_location = String.duplicate("a", 1001)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_location", %{"value" => long_location})

      assert render(lv) =~ "Input too long"
    end
  end

  describe "inline description editing" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Description Event",
          description: "Original notes",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, event: event}
    end

    test "shows editable description textarea for owned events", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()

      assert html =~ "event-description-input"
      assert html =~ "Original notes"
    end

    test "saves description on blur", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_description", %{"value" => "Updated notes"})

      assert html =~ "Updated notes"
    end

    test "does not save when description is unchanged", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_description", %{"value" => "Original notes"})

      assert html =~ "Original notes"
    end

    test "shows placeholder when event has no description", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "No Notes Event",
          description: nil,
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()

      assert html =~ "Add description"
    end

    test "rejects description exceeding max length", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()

      long_desc = String.duplicate("a", 5001)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_description", %{"value" => long_desc})

      assert render(lv) =~ "Input too long"
    end
  end

  describe "inline time editing" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Timed Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, event: event}
    end

    test "shows editable date and time inputs for owned events", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#event-#{event.id}") |> render_click()

      assert html =~ "event-start-date"
      assert html =~ "event-start-time"
      assert html =~ "event-end-date"
      assert html =~ "event-end-time"
    end

    test "updates event time on form change", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()
      today_iso = Date.to_iso8601(Date.utc_today())

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_time", %{
          "start-date" => today_iso,
          "start-time" => "14:00",
          "end-date" => today_iso,
          "end-time" => "15:30"
        })

      # The editable form reflects the new local times as input values
      assert html =~ ~s(value="14:00")
      assert html =~ ~s(value="15:30")
    end

    test "auto-adjusts end when start moves past end", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()
      today_iso = Date.to_iso8601(Date.utc_today())

      # Original: 10:00-11:00 (1 hour). Move start to 23:00 with end still at 11:00
      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_time", %{
          "start-date" => today_iso,
          "start-time" => "23:00",
          "end-date" => today_iso,
          "end-time" => "11:00"
        })

      # Start was moved to 23:00 local; end was auto-adjusted (1h preserved)
      assert html =~ ~s(value="23:00")
      # End will be 00:00 next day (1h after 23:00)
      assert html =~ ~s(value="00:00")
    end

    test "skips save when times are unchanged", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()
      today_iso = Date.to_iso8601(Date.utc_today())

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_time", %{
          "start-date" => today_iso,
          "start-time" => "10:00",
          "end-date" => today_iso,
          "end-time" => "11:00"
        })

      refute html =~ "error"
    end

    test "triggers recurrence prompt for recurring events", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Recurring Timed Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false,
          recurring_event_id: "master-event-456"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#event-#{event.id}") |> render_click()
      today_iso = Date.to_iso8601(Date.utc_today())

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_time", %{
          "start-date" => today_iso,
          "start-time" => "14:00",
          "end-date" => today_iso,
          "end-time" => "15:00"
        })

      assert html =~ "Edit recurring event"
    end
  end

  # Extracts the text content of the first <h2> element found in HTML.
  defp extract_period_label(html) do
    case Regex.run(~r/<h2[^>]*>(.*?)<\/h2>/s, html) do
      [_match, text] -> String.trim(text)
      _no_match -> ""
    end
  end

  defp insert_event(integration, attrs) do
    insert(:calendar_event_cache, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
