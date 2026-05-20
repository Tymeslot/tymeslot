defmodule TymeslotWeb.Dashboard.CalendarGrid.EventsRenderingTest do
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
        summary: "My Test Meeting",
        start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "My Test Meeting"
    end

    test "hides events from calendars the user has deselected", %{conn: conn, user: user} do
      # The integration setting screen lets users toggle individual calendars
      # on or off. That toggle is the single source of truth for what the app
      # may surface: the grid must respect it even when previously-synced
      # rows still linger in the cache for the deselected calendar.
      selected_path = "/cal/work/"
      deselected_path = "/cal/personal/"

      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: [selected_path],
          calendar_list: [
            %{"id" => selected_path, "path" => selected_path, "selected" => true},
            %{"id" => deselected_path, "path" => deselected_path, "selected" => false}
          ]
        )

      today = Date.utc_today()
      start_at = DateTime.new!(today, ~T[10:00:00], "Etc/UTC")
      end_at = DateTime.new!(today, ~T[11:00:00], "Etc/UTC")

      insert_event(integration, %{
        summary: "Work Meeting",
        start_at: start_at,
        end_at: end_at,
        all_day: false,
        provider: "caldav",
        provider_calendar_id: selected_path,
        provider_event_id: selected_path <> "work-evt.ics"
      })

      insert_event(integration, %{
        summary: "Personal Errand",
        start_at: start_at,
        end_at: end_at,
        all_day: false,
        provider: "caldav",
        provider_calendar_id: selected_path,
        provider_event_id: deselected_path <> "personal-evt.ics"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")

      assert html =~ "Work Meeting"
      refute html =~ "Personal Errand"
    end

    test "all-day event appears in banner row", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        summary: "All Day Conference",
        start_date: Date.utc_today(),
        end_date: Date.add(Date.utc_today(), 1),
        start_at: DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.add(Date.utc_today(), 1), ~T[00:00:00], "Etc/UTC"),
        all_day: true
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "All Day Conference"
      assert html =~ "calendar-allday-row"
    end

    test "renders 3+ overlapping all-day events without crashing (issue #50)",
         %{conn: conn, user: user} do
      # Regression: grid_views.ex's all-day disclosure branch referenced
      # @allday_visible_limit inside HEEx, which resolves to assigns rather
      # than the module attribute, raising KeyError whenever a day held more
      # all-day events than the cap. Triggered by Zimbra returning 3+
      # overlapping all-day events for a single day.
      integration = insert(:calendar_integration, user: user, is_active: true)
      today = Date.utc_today()
      tomorrow = Date.add(today, 1)
      midnight_today = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
      midnight_tomorrow = DateTime.new!(tomorrow, ~T[00:00:00], "Etc/UTC")

      for summary <- ["All Day One", "All Day Two", "All Day Three"] do
        insert_event(integration, %{
          summary: summary,
          start_date: today,
          end_date: tomorrow,
          start_at: midnight_today,
          end_at: midnight_tomorrow,
          all_day: true
        })
      end

      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")

      assert html =~ "All Day One"
      assert html =~ "All Day Two"
      assert html =~ "All Day Three"
      assert html =~ "+1 more"
    end

    test "opens event detail modal on click", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      start_utc = DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC")
      end_utc = DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC")

      event =
        insert_event(integration, %{
          summary: "Clickable Event",
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
          summary: "Off-site Meetup",
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
          summary: "Planning Session",
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
          summary: "Team Sync",
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
          summary: "Anonymous Meeting",
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
          summary: "Close Me",
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

  describe "PubSub live updates" do
    test "re-renders events when :calendar_events_updated is broadcast", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        summary: "Live Update Event",
        start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Live Update Event"

      insert_event(integration, %{
        summary: "New Live Event",
        start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
        all_day: false
      })

      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        "calendar_events:#{user.id}",
        {:calendar_events_updated, user.id, []}
      )

      # First render flushes the handle_info, which calls send_update on the component.
      # Second render processes the send_update, triggering the event reload.
      render(lv)
      assert render(lv) =~ "New Live Event"
    end
  end

  describe "PubSub calendar_sync_complete" do
    test "refreshes the grid so newly-synced events appear", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      refute html =~ "Synced Event"

      insert_event(integration, %{
        summary: "Synced Event",
        start_at: DateTime.new!(Date.utc_today(), ~T[16:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[17:00:00], "Etc/UTC"),
        all_day: false
      })

      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        "calendar_events:#{user.id}",
        {:calendar_sync_complete, user.id, integration.id}
      )

      render(lv)
      assert render(lv) =~ "Synced Event"
    end
  end

  describe "graceful rendering of sparse event data" do
    test "renders events with nil summary gracefully", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        summary: nil,
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
          summary: "No Description Event",
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
          summary: "Solo Meeting",
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

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
