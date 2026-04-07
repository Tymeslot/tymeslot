defmodule TymeslotWeb.Dashboard.CalendarGrid.EventsTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Profiles

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
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

      start_utc = DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC")
      end_utc = DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC")

      event =
        insert_event(integration, %{
          title: "Clickable Event",
          start_at: start_utc,
          end_at: end_utc,
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      tz = Profiles.get_user_timezone(user.id)
      start_local = DateTime.shift_zone!(start_utc, tz)
      expected_time = Calendar.strftime(start_local, "%-I:%M %p")

      assert html =~ "Clickable Event"
      assert html =~ expected_time
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
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()
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
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()
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
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()
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
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()
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
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      # Dismiss via the close_event_detail event rather than targeting a specific button
      lv |> element("#calendar-grid") |> render_hook("close_event_detail", %{})
      html = render(lv)
      refute html =~ "modal-overlay"
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
    setup %{user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)
      :ok
    end

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

    test "shows separate start and end date fields", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today_iso = Date.to_iso8601(Date.utc_today())

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

      assert html =~ ~s(id="create-event-start-date")
      assert html =~ ~s(id="create-event-end-date")
    end

    test "defaults end-date to start date when not provided", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today_iso = Date.to_iso8601(Date.utc_today())

      html =
        lv
        |> element("#calendar-create-zone")
        |> render_hook("show_create_form", %{
          "date" => today_iso,
          "start-hour" => "14",
          "start-minute" => "0",
          "end-hour" => "15",
          "end-minute" => "0"
        })

      # Both date fields should show today's date
      assert html =~ ~s(name="start-date" value="#{today_iso}")
      assert html =~ ~s(name="end-date" value="#{today_iso}")
    end

    test "accepts separate end-date from cross-day drag", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today = Date.utc_today()
      tomorrow = Date.add(today, 1)
      today_iso = Date.to_iso8601(today)
      tomorrow_iso = Date.to_iso8601(tomorrow)

      html =
        lv
        |> element("#calendar-create-zone")
        |> render_hook("show_create_form", %{
          "date" => today_iso,
          "end-date" => tomorrow_iso,
          "start-hour" => "14",
          "start-minute" => "0",
          "end-hour" => "10",
          "end-minute" => "0"
        })

      assert html =~ ~s(name="start-date" value="#{today_iso}")
      assert html =~ ~s(name="end-date" value="#{tomorrow_iso}")
    end

    test "updates start-date and end-date independently via form change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today = Date.utc_today()
      tomorrow = Date.add(today, 1)
      today_iso = Date.to_iso8601(today)
      tomorrow_iso = Date.to_iso8601(tomorrow)

      lv
      |> element("#calendar-create-zone")
      |> render_hook("show_create_form", %{
        "date" => today_iso,
        "start-hour" => "10",
        "start-minute" => "0",
        "end-hour" => "11",
        "end-minute" => "0"
      })

      # Change only the end-date
      html =
        lv
        |> element("#create-event-modal form[phx-change=update_create_time]")
        |> render_change(%{
          "start-date" => today_iso,
          "end-date" => tomorrow_iso,
          "start-time" => "10:00",
          "end-time" => "11:00"
        })

      assert html =~ ~s(name="start-date" value="#{today_iso}")
      assert html =~ ~s(name="end-date" value="#{tomorrow_iso}")
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
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()
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
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()
      assert html =~ "Solo Meeting"
    end
  end

  describe "attendee management" do
    test "adding an attendee persists immediately and clears input", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Team Sync",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: []
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # Open event detail modal
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      # Submit attendee form
      html =
        lv
        |> element("form[phx-submit=add_event_attendee]")
        |> render_submit(%{"email" => "colleague@example.com"})

      assert html =~ "colleague@example.com"
      assert html =~ ~s(id="edit-attendee-email")
    end

    test "adding a duplicate attendee is a no-op", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Team Sync",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [%{"email" => "existing@example.com"}]
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("form[phx-submit=add_event_attendee]")
        |> render_submit(%{"email" => "existing@example.com"})

      # Should still have only one attendee entry (not duplicated)
      assert html =~ "existing@example.com"

      # Count remove buttons — each attendee gets exactly one
      remove_count = html |> String.split("request_remove_attendee") |> length() |> Kernel.-(1)
      assert remove_count == 1, "Expected 1 attendee, but found #{remove_count} remove buttons"
    end

    test "adding an invalid email is a no-op", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Team Sync",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: []
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("form[phx-submit=add_event_attendee]")
        |> render_submit(%{"email" => "not-an-email"})

      refute html =~ "not-an-email"
    end
  end

  describe "pending attendee validation" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          title: "Validation Test Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [
            %{"email" => "existing@example.com", "name" => "Existing", "status" => "accepted"}
          ]
        })

      {:ok, integration: integration, event: event}
    end

    test "rejects invalid email format", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_attendee", %{"email" => "not-an-email"})

      refute html =~ "not-an-email"
    end

    test "rejects duplicate of existing attendee", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_attendee", %{"email" => "existing@example.com"})

      # Should not appear as a pending attendee (dashed border = pending tag)
      refute html =~ "border-dashed"
    end

    test "rejects duplicate pending attendee", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("add_event_attendee", %{"email" => "unique-new@example.com"})

      # Adding the same email again should not increase the pending count
      html_before = render(lv)
      before_count = length(String.split(html_before, "unique-new@example.com")) - 1

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_attendee", %{"email" => "unique-new@example.com"})

      after_count = length(String.split(html, "unique-new@example.com")) - 1
      assert after_count == before_count
    end
  end

  describe "create form attendee management" do
    setup %{user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)
      :ok
    end

    test "adds an attendee to the create form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_create_form(lv)

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_create_attendee", %{"email" => "invitee@example.com"})

      assert html =~ "invitee@example.com"
    end

    test "removes an attendee from the create form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_create_form(lv)

      lv
      |> element("#calendar-grid")
      |> render_hook("add_create_attendee", %{"email" => "tobe-removed@example.com"})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("remove_create_attendee", %{"email" => "tobe-removed@example.com"})

      refute html =~ "tobe-removed@example.com"
    end

    test "closing create form with pending attendees shows discard confirmation", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_create_form(lv)

      lv
      |> element("#calendar-grid")
      |> render_hook("add_create_attendee", %{"email" => "invited@example.com"})

      html = lv |> element("#create-event-modal button", "Cancel") |> render_click()

      assert html =~ "Unsent invitations"
    end

    test "discarding clears the create form and pending attendees", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_create_form(lv)

      lv
      |> element("#calendar-grid")
      |> render_hook("add_create_attendee", %{"email" => "discard-me@example.com"})

      lv |> element("#create-event-modal button", "Cancel") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("discard_pending_attendees", %{})

      refute html =~ "discard-me@example.com"
      refute html =~ "New Event"
    end
  end

  defp open_create_form(lv) do
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
  end

  defp insert_event(integration, attrs) do
    insert(:calendar_event_cache, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
