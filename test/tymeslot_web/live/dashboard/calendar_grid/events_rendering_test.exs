defmodule TymeslotWeb.Dashboard.CalendarGrid.EventsRenderingTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
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

  describe "async event update failure" do
    test "reverts event and shows error flash when update fails", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Failing Event",
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

  describe "async event create result" do
    test "caches new event and refreshes grid when task reports success", %{
      conn: conn,
      user: user
    } do
      # Regression: the dashboard create flow runs in a Task that sends
      # {:create_event_result, ...} back to the LiveView pid. Two historical bugs
      # crashed this path:
      #
      # 1. EventCreate.handle_create_result/2 looked up integrations on the
      #    parent LiveView socket, which never carries the :integrations assign.
      # 2. CalendarGrid.cache_created_event/1 received second-precision
      #    DateTimes built from DateTime.new!, but the schema requires
      #    microsecond precision.
      integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      start_at = DateTime.new!(Date.utc_today(), ~T[15:45:00], "Etc/UTC")
      end_at = DateTime.new!(Date.utc_today(), ~T[16:15:00], "Etc/UTC")

      creating = %{
        date: Date.to_iso8601(Date.utc_today()),
        end_date: Date.to_iso8601(Date.utc_today()),
        title: "Dashboard Created Event",
        integration_id: integration.id,
        calendar_id: "primary",
        attendees: [],
        attendee_input: "",
        video_integration_id: nil,
        start_hour: 15,
        start_minute: 45,
        end_hour: 16,
        end_minute: 15
      }

      send(
        lv.pid,
        {:create_event_result,
         {:ok,
          %{
            uid: "dashboard-created-uid",
            creating: creating,
            start_at: start_at,
            end_at: end_at,
            provider: "google",
            default_booking_calendar_id: "primary",
            attendees: [],
            meeting_url: nil,
            description: nil
          }}}
      )

      # First render flushes handle_info and the send_update to the component;
      # second render processes the event_created action and reloads events.
      render(lv)
      assert render(lv) =~ "Dashboard Created Event"
    end
  end

  describe "async event move result" do
    test "error path reverts event and flashes", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Move Me",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:event_move_result, {:error, original_event: event, reason: :api_error}})

      html = render(lv)
      assert html =~ "Failed to move event"
      assert html =~ "Move Me"
    end

    test "success path keeps the grid rendering without errors", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Moved Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(
        lv.pid,
        {:event_move_result, {:ok, uid: event.uid, integration_id: integration.id}}
      )

      render(lv)
      html = render(lv)
      refute html =~ "Failed to move event"
      assert html =~ "Moved Event"
    end
  end

  describe "async event delete result" do
    test "success path removes event from cache and grid", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Delete Me",
          start_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[12:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Delete Me"

      send(
        lv.pid,
        {:delete_event_result, {:ok, %{uid: event.uid, integration_id: integration.id}}}
      )

      render(lv)
      html = render(lv)
      refute html =~ "Delete Me"

      assert {:error, :not_found} = CalendarGrid.get_cached_event(integration.id, event.uid)
    end

    test "error path flashes failure message", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        summary: "Stubborn Event",
        start_at: DateTime.new!(Date.utc_today(), ~T[13:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:delete_event_result, {:error, :api_error}})

      html = render(lv)
      assert html =~ "Failed to delete event"
      assert html =~ "Stubborn Event"
    end
  end

  describe "async ad-hoc meeting result" do
    test "success path flashes confirmation", %{conn: conn, user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:create_ad_hoc_meeting_result, {:ok, %{meeting_id: 1}}})

      html = render(lv)
      assert html =~ "Meeting created and invitation sent"
    end

    test "error path flashes the reason", %{conn: conn, user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:create_ad_hoc_meeting_result, {:error, "Calendar unavailable"}})

      html = render(lv)
      assert html =~ "Calendar unavailable"
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

  describe "integration lifecycle messages" do
    test "integration_added keeps the dashboard rendering", %{conn: conn, user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:integration_added, nil})

      assert render(lv) =~ "calendar"
    end

    test "integration_removed keeps the dashboard rendering", %{conn: conn, user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:integration_removed, nil})

      assert render(lv) =~ "calendar"
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

  describe "async create failure with CalDAV offline queue" do
    test "tags cache row for retry and shows queued flash", %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: ["/cal/"]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      uid = "offline-create-#{System.unique_integer([:positive])}"

      send(
        lv.pid,
        {:create_event_result,
         {:error, :server_error,
          %{
            uid: uid,
            calendar_integration_id: integration.id,
            summary: "Offline Create",
            start_time: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
            end_time: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
            location: nil,
            description: nil,
            timezone: "Etc/UTC"
          }}}
      )

      html = render(lv)
      assert html =~ "queued to retry on next sync"

      assert {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
      assert cached.sync_state == "locally_created"
      assert cached.summary == "Offline Create"
    end
  end

  describe "async delete failure with CalDAV offline queue" do
    test "tags cache row for retry and shows queued flash", %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: ["/cal/"]
        )

      event =
        insert_event(integration, %{
          uid: "offline-delete-#{System.unique_integer([:positive])}",
          summary: "Offline Delete",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false,
          provider: "caldav",
          provider_calendar_id: "/cal/"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # The delete error path passes the context directly (uid + calendar_integration_id)
      context = %{uid: event.uid, calendar_integration_id: integration.id}

      send(lv.pid, {:delete_event_result, {:error, :server_error, context}})

      html = render(lv)
      assert html =~ "queued to retry on next sync"

      assert {:ok, cached} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)

      assert cached.sync_state == "locally_deleted"
    end
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
