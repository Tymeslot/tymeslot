defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceRemindersTest do
  @moduledoc """
  Desktop notifications on the calendar: the feed the `DesktopReminders`
  hook fires from (`#calendar-reminder-feed`), built from the calendars the
  surface shows, and the 60-second loop that keeps it fresh without a
  clock tick.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Phoenix.LiveView, only: [send_update: 3]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesSchema
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.Calendar.ReminderFeed

  @popup [%{"method" => "popup", "minutes_before" => 10}]

  # 15:00 in London on the frozen Wednesday, six hours after "now".
  defp reminded(integration, calendar_id, summary),
    do: event(integration, calendar_id, summary, ~U[2026-10-14 14:00:00Z], 60, reminders: @popup)

  defp feed(lv), do: lv |> element("#calendar-reminder-feed") |> render()

  defp canvas(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  describe "the feed" do
    test "lists each upcoming event with a reminder, formatted in the organiser's clock", %{
      conn: conn
    } do
      %{conn: conn, integration: integration} =
        owner(conn, preferences: [desktop_reminders_enabled: true])

      reminded(integration, "work", "Design review")
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html = feed(lv)
      assert html =~ ~s(data-enabled="true")
      assert html =~ "Reminder: Design review"
      assert html =~ "Today at 15:00"
      assert html =~ ~s(phx-hook="DesktopReminders")
    end

    test "is empty and disabled while the preference is off", %{conn: conn} do
      %{conn: conn, integration: integration} = owner(conn)
      reminded(integration, "work", "Design review")
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html = feed(lv)
      assert html =~ ~s(data-enabled="false")
      assert html =~ ~s(data-reminders="[]")
    end

    test "leaves out a calendar hidden in the rail, and takes it back when shown", %{
      conn: conn
    } do
      %{conn: conn, integration: integration} =
        owner(conn, preferences: [desktop_reminders_enabled: true])

      reminded(integration, "work", "Design review")
      reminded(integration, "family", "School run")
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      assert feed(lv) =~ "School run"

      canvas(lv, "calendar:toggle_calendar", %{
        "integration-id" => to_string(integration.id),
        "calendar-id" => "family"
      })

      refute feed(lv) =~ "School run"
      assert feed(lv) =~ "Design review"

      canvas(lv, "calendar:show_all", %{})
      assert feed(lv) =~ "School run"
    end

    test "leaves out a hidden account", %{conn: conn} do
      %{conn: conn, integration: integration} =
        owner(conn, preferences: [desktop_reminders_enabled: true])

      reminded(integration, "work", "Design review")
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      canvas(lv, "calendar:toggle_account", %{"integration-id" => to_string(integration.id)})

      refute feed(lv) =~ "Design review"
    end

    test "switching notifications on in display options fills the feed at once", %{conn: conn} do
      %{conn: conn, user: user, integration: integration} = owner(conn)
      reminded(integration, "work", "Design review")
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-display-options > button") |> render_click()

      lv
      |> element("#calendar-desktop-reminders")
      |> render_hook("calendar:enable_desktop_reminders", %{"permission" => "granted"})

      assert feed(lv) =~ ~s(data-enabled="true")
      assert feed(lv) =~ "Reminder: Design review"
      assert CalendarPreferencesQueries.get_or_create(user.id).desktop_reminders_enabled

      lv |> element("#calendar-desktop-reminders") |> render_click()
      assert feed(lv) =~ ~s(data-reminders="[]")
    end

    test "a clock change rewrites the bodies", %{conn: conn} do
      %{conn: conn, integration: integration} =
        owner(conn, preferences: [desktop_reminders_enabled: true])

      reminded(integration, "work", "Design review")
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-display-options > button") |> render_click()
      lv |> element("#calendar-time-format-12h") |> render_click()

      assert feed(lv) =~ "Today at 3:00 PM"
    end

    test "is rebuilt when a sync reloads the calendar", %{conn: conn} do
      %{conn: conn, integration: integration} =
        owner(conn, preferences: [desktop_reminders_enabled: true])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      refute feed(lv) =~ "Design review"

      reminded(integration, "work", "Design review")

      # A sync's refresh message, then the coalesced reload it schedules
      # (sent at once rather than after its 250 ms), as the guests tests do.
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :events_updated)
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :reload)

      assert feed(lv) =~ "Design review"
    end
  end

  describe "the refresh loop" do
    # A connected socket as the surface holds it, without the LiveView.
    defp socket(integration, enabled) do
      %Socket{
        transport_pid: self(),
        assigns: %{
          __changed__: %{},
          id: "calendar",
          preferences: %CalendarPreferencesSchema{desktop_reminders_enabled: enabled},
          integrations: [integration],
          hidden_integration_ids: [],
          hidden_calendar_keys: MapSet.new(),
          timezone: "Europe/London",
          time_format: "24h",
          reminder_feed: [],
          reminder_ref: nil
        }
      }
    end

    test "a tick from the live loop rebuilds the feed and starts the next loop", %{conn: conn} do
      %{integration: integration} = owner(conn)
      started = ReminderFeed.refresh(socket(integration, true))
      ref = started.assigns.reminder_ref
      assert is_reference(ref)
      assert started.assigns.reminder_feed == []

      reminded(integration, "work", "Design review")
      ticked = ReminderFeed.tick(started, ref)

      assert [%{title: "Reminder: Design review"}] = ticked.assigns.reminder_feed
      assert is_reference(ticked.assigns.reminder_ref)
      refute ticked.assigns.reminder_ref == ref
    end

    test "a stale tick changes nothing", %{conn: conn} do
      %{integration: integration} = owner(conn)
      started = ReminderFeed.refresh(socket(integration, true))

      reminded(integration, "work", "Design review")
      ticked = ReminderFeed.tick(started, make_ref())

      assert ticked.assigns.reminder_feed == []
      assert ticked.assigns.reminder_ref == started.assigns.reminder_ref
    end

    test "switching off makes an in-flight tick stale", %{conn: conn} do
      %{integration: integration} = owner(conn)
      started = ReminderFeed.refresh(socket(integration, true))
      first = started.assigns.reminder_ref

      off = %{
        started
        | assigns: %{
            started.assigns
            | preferences: %CalendarPreferencesSchema{desktop_reminders_enabled: false}
          }
      }

      stopped = ReminderFeed.refresh(off)
      reminded(integration, "work", "Design review")
      ticked = ReminderFeed.tick(stopped, first)

      assert ticked.assigns.reminder_feed == []
      assert ticked.assigns.reminder_ref == nil
    end

    test "assign_feed starts a loop when the preference is on and none is live", %{conn: conn} do
      %{integration: integration} = owner(conn)
      reminded(integration, "work", "Design review")

      started = ReminderFeed.assign_feed(socket(integration, true))

      assert is_reference(started.assigns.reminder_ref)
      assert [%{title: "Reminder: Design review"}] = started.assigns.reminder_feed
    end

    test "assign_feed leaves a live loop unchanged", %{conn: conn} do
      %{integration: integration} = owner(conn)
      started = ReminderFeed.refresh(socket(integration, true))

      again = ReminderFeed.assign_feed(started)

      assert again.assigns.reminder_ref == started.assigns.reminder_ref
    end

    test "nothing is scheduled while the preference is off", %{conn: conn} do
      %{integration: integration} = owner(conn)
      reminded(integration, "work", "Design review")

      stopped = ReminderFeed.refresh(socket(integration, false))

      assert stopped.assigns.reminder_ref == nil
      assert stopped.assigns.reminder_feed == []
    end
  end
end
