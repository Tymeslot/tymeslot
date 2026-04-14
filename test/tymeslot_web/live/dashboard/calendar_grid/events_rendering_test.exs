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
            default_booking_calendar_id: "primary"
          }}}
      )

      # First render flushes handle_info and the send_update to the component;
      # second render processes the event_created action and reloads events.
      render(lv)
      assert render(lv) =~ "Dashboard Created Event"
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
