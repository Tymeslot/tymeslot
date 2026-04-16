defmodule TymeslotWeb.Dashboard.CalendarGrid.InlineEditTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Security.RateLimiter

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "inline title editing" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      today = Date.utc_today()

      event =
        insert_event(integration, %{
          summary: "Team Standup",
          start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, event: event}
    end

    test "shows editable title input for owned events", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "event-title-input"
      assert html =~ ~s(name="value")
      assert html =~ "Team Standup"
    end

    test "saves title on blur", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_title", %{"value" => "Renamed Standup"})

      assert html =~ "Renamed Standup"
    end

    test "does not save when title is unchanged", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_title", %{"value" => "Team Standup"})

      refute html =~ "error"
      assert html =~ "Team Standup"
    end

    test "sanitises malicious input in title", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_title", %{"value" => "<script>alert('xss')</script>"})

      refute html =~ "<script>"
      assert html =~ "alert"
    end

    test "rejects title exceeding max length", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

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
          summary: "Location Event",
          location: "Room 101",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, event: event}
    end

    test "shows editable location input for owned events", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "event-location-input"
      assert html =~ "Room 101"
    end

    test "saves location on blur", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_location", %{"value" => "Room 202"})

      assert html =~ "Room 202"
    end

    test "does not save when location is unchanged", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

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
          summary: "No Location Event",
          location: nil,
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "Add location"
    end

    test "rejects location exceeding max length", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

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
          summary: "Description Event",
          description: "Original notes",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, event: event}
    end

    test "shows editable description textarea for owned events", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "event-description-input"
      assert html =~ "Original notes"
    end

    test "saves description on blur", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_description", %{"value" => "Updated notes"})

      assert html =~ "Updated notes"
    end

    test "does not save when description is unchanged", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

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
          summary: "No Notes Event",
          description: nil,
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "Add description"
    end

    test "rejects description exceeding max length", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

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
          summary: "Timed Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, event: event}
    end

    test "shows editable date and time inputs for owned events", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "event-start-date"
      assert html =~ "event-start-time"
      assert html =~ "event-end-date"
      assert html =~ "event-end-time"
    end

    test "updates event time on form change", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
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
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
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
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
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
          summary: "Recurring Timed Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false,
          recurring_event_id: "master-event-456"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
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

    test "rejects time edit for all-day events with an info flash", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      today = Date.utc_today()

      event =
        insert_event(integration, %{
          summary: "All Day Workshop",
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

      today_iso = Date.to_iso8601(today)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_time", %{
        "start-date" => today_iso,
        "start-time" => "09:00",
        "end-date" => today_iso,
        "end-time" => "10:00"
      })

      # Flash message propagates to the parent LiveView on the next render
      assert render(lv) =~ "all-day"
    end
  end

  describe "send invitations" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Invite Test Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: []
        })

      {:ok, event: event}
    end

    test "new attendees are rendered after send_invitations", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("add_event_attendee", %{"email" => "new-invite@example.com"})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("send_invitations", %{})

      # Attendee email must be visible in the modal after invitations are sent
      assert html =~ "new-invite@example.com"
      # Pending list must be cleared
      refute html =~ "border-dashed"
    end

    test "shows warning flash when rate limit is exceeded on send_invitations", %{
      conn: conn,
      event: event,
      user: user
    } do
      # Exhaust the per-user edit bucket before mounting
      for _i <- 1..30 do
        RateLimiter.check_calendar_event_edit_rate_limit(user.id)
      end

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("add_event_attendee", %{"email" => "rate-limited@example.com"})

      lv
      |> element("#calendar-grid")
      |> render_hook("send_invitations", %{})

      assert render(lv) =~ "Too many edits"
    end
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
