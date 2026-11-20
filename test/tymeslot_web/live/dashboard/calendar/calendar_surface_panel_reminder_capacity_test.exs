defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePanelReminderCapacityTest do
  @moduledoc """
  The side panel's reminders on an event whose calendar keeps one
  notification (Outlook, Exchange): the add row offers no method, gives way
  once the event has its one reminder, and what it adds is written as a
  notification whatever method the row sent. The calendar's provider is
  read from the organiser's accounts, as the surface loads them.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.Reminder

  for provider <- ["outlook", "exchange"] do
    describe "on an #{provider} calendar" do
      @describetag provider: provider

      setup %{conn: conn, provider: provider} do
        context = owner(conn)
        test_pid = self()

        Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
          send(test_pid, {:written, uid, payload})
          :ok
        end)

        account =
          insert(:calendar_integration,
            user: context.user,
            name: "One-alarm account",
            provider: provider,
            is_active: true,
            calendar_list: [%{"id" => "cal", "name" => "Calendar", "selected" => true}]
          )

        bare = event(account, "cal", "Dentist", ~U[2026-10-15 14:00:00Z], 60, provider: provider)

        alarmed =
          event(account, "cal", "Review", ~U[2026-10-15 16:00:00Z], 60,
            provider: provider,
            reminders: [%{"method" => "popup", "minutes_before" => 30}]
          )

        # The window is read on mount, so the page is opened after the events exist.
        {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")
        %{lv: lv, bare: bare, alarmed: alarmed}
      end

      test "the add row offers no method choice", %{lv: lv, bare: bare} do
        edit(lv, bare)

        assert has_element?(lv, "#calendar-panel-reminder-add")
        assert has_element?(lv, "#calendar-panel-reminder-minutes")
        refute has_element?(lv, "#calendar-panel-reminder-method")
      end

      test "a reminder asked for as an email is written as a notification", %{
        lv: lv,
        bare: bare
      } do
        edit(lv, bare)

        lv
        |> element("#calendar-panel-reminder-add")
        |> render_submit(%{"minutes" => "10", "method" => "email"})

        uid = bare.uid
        assert_receive {:written, ^uid, payload}
        assert alarms(payload.reminders) == [{:popup, 10}]
      end

      test "the add row gives way once the event has its one reminder", %{
        lv: lv,
        alarmed: alarmed
      } do
        edit(lv, alarmed)

        assert has_element?(
                 lv,
                 "#calendar-panel-reminder-list button[aria-label='Remove reminder Notification 30 minutes before']"
               )

        refute has_element?(lv, "#calendar-panel-reminder-add")
      end
    end
  end

  defp edit(lv, event) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{event.id}"})

    lv
  end

  defp alarms(reminders),
    do: Enum.map(reminders, &{Reminder.method(&1), Reminder.minutes_before(&1)})
end
