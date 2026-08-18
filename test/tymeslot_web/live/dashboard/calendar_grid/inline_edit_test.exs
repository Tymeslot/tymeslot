defmodule TymeslotWeb.Dashboard.CalendarGrid.InlineEditTest do
  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Workers.EmailWorker

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

      assert html =~ "Team Standup"

      # A save reports itself with the "Changes saved." flash; an unchanged
      # value must short-circuit before any write.
      refute render(lv) =~ "Changes saved."
    end

    test "preserves benign angle-bracket symbols in title", %{conn: conn, event: event} do
      # Plain-text fields rely on Phoenix template auto-escaping for XSS
      # protection rather than stripping every `<...>` substring. This keeps
      # natural punctuation like `<>`, `<3`, and `<email@x.com>` intact when
      # the user types them as part of a meeting title.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_title", %{"value" => "Luka <> Paul"})

      assert html =~ "Luka &lt;&gt; Paul"
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

      # No save happened, so no "Changes saved." flash.
      refute render(lv) =~ "Changes saved."
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

      # No save happened, so no "Changes saved." flash.
      refute render(lv) =~ "Changes saved."
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
      opened = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      # Echo back exactly what the form shows. The inputs carry the organiser's
      # local times, which are not the stored UTC ones, so hard-coding the UTC
      # values here would submit a genuine change.
      unchanged = %{
        "start-date" => input_value(opened, "event-start-date"),
        "start-time" => input_value(opened, "event-start-time"),
        "end-date" => input_value(opened, "event-end-date"),
        "end-time" => input_value(opened, "event-end-time")
      }

      html = lv |> element("#calendar-grid") |> render_hook("update_event_time", unchanged)

      # The form still shows the original window …
      assert input_value(html, "event-start-time") == unchanged["start-time"]
      assert input_value(html, "event-end-time") == unchanged["end-time"]

      # … and no save was performed.
      refute render(lv) =~ "Changes saved."
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

  describe "attendee add/remove notifications" do
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

      event_with_guest =
        insert_event(integration, %{
          summary: "Existing Attendee Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[16:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[17:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [%{"email" => "guest@example.com", "name" => "Guest"}]
        })

      {:ok, event: event, event_with_guest: event_with_guest}
    end

    test "adding an attendee enqueues an invitation and flashes confirmation",
         %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_attendee", %{"email" => "new-invite@example.com"})

      assert html =~ "new-invite@example.com"
      assert render(lv) =~ "Attendee added and invited."

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "new-invite@example.com",
          "method" => "request"
        }
      )
    end

    test "removing an attendee enqueues a CANCEL and flashes confirmation",
         %{conn: conn, event_with_guest: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("request_remove_attendee", %{"email" => "guest@example.com"})

      lv
      |> element("#calendar-grid")
      |> render_hook("confirm_remove_attendee", %{})

      assert render(lv) =~ "Attendee removed and notified."

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "guest@example.com",
          "method" => "cancel"
        }
      )
    end

    test "edit modal no longer renders a Send invitations button",
         %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      refute html =~ "Send invitations"
      refute html =~ ~s(phx-click="send_invitations")
    end
  end

  describe "video integration selector on edit" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)
      video_integration = insert(:video_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Video Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false,
          video_integration_id: nil
        })

      {:ok, event: event, video_integration: video_integration}
    end

    test "shows video selector in edit modal", %{
      conn: conn,
      event: event,
      video_integration: video_integration
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "update_edit_video"
      assert html =~ video_integration.name
      assert html =~ "None"
    end

    test "selecting a video integration marks it active", %{
      conn: conn,
      event: event,
      video_integration: video_integration
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_edit_video", %{
          "video_integration_id" => to_string(video_integration.id)
        })

      # The active provider button gains the turquoise-400 border class.
      assert html =~ "border-turquoise-400"
      assert html =~ video_integration.name
    end

    test "selecting None clears the video integration", %{
      conn: conn,
      event: event,
      video_integration: video_integration
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      # First pick a provider.
      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{
        "video_integration_id" => to_string(video_integration.id)
      })

      # The provider button is the active one while it is selected.
      assert has_element?(
               lv,
               ~s|button[phx-value-video_integration_id="#{video_integration.id}"].border-turquoise-400|
             )

      # Then clear it.
      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{"video_integration_id" => ""})

      # After clearing, None is the active (turquoise-400) button and the
      # provider button is no longer active.
      assert has_element?(lv, ~s|button[phx-value-video_integration_id=""].border-turquoise-400|)

      refute has_element?(
               lv,
               ~s|button[phx-value-video_integration_id="#{video_integration.id}"].border-turquoise-400|
             )
    end
  end

  defp input_value(html, id) do
    html
    |> Floki.parse_fragment!()
    |> Floki.attribute("##{id}", "value")
    |> hd()
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
