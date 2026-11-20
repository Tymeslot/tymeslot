defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceTransferRemindersTest do
  @moduledoc """
  Moving an event to a calendar that keeps fewer reminders than it has
  (Outlook and Exchange keep one notification): the move goes ahead with
  the reminders the destination keeps, and the toast says not all of them
  came across.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CreatedEvent

  @task_timeout 5_000

  setup :verify_on_exit!

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), {:create, payload}})
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    stub(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
      send(test_pid, {:provider_call, self(), {:delete, uid}})
      :ok
    end)

    outlook =
      insert(:calendar_integration,
        user: context.user,
        name: "Outlook account",
        provider: "outlook",
        is_active: true,
        calendar_list: [%{"id" => "cal", "name" => "Outlook", "selected" => true}]
      )

    exchange =
      insert(:calendar_integration,
        user: context.user,
        name: "Exchange account",
        provider: "exchange",
        is_active: true,
        calendar_list: [%{"id" => "ews", "name" => "Exchange", "selected" => true}]
      )

    planning =
      event(context.integration, "work", "Planning", ~U[2026-10-15 09:00:00Z], 60,
        reminders: [
          %{"method" => "popup", "minutes_before" => 10},
          %{"method" => "email", "minutes_before" => 1440}
        ]
      )

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{planning.id}"})

    Map.merge(context, %{lv: lv, outlook: outlook, exchange: exchange})
  end

  defp choose_calendar(lv, key),
    do: lv |> form("#calendar-panel-calendar-form") |> render_change(%{"calendar" => key})

  # The create and the delete run in one task; once it has exited, the
  # LiveView takes the result and the surface applies it.
  defp await_move(lv) do
    assert_receive {:provider_call, task_pid, {:create, payload}}, @task_timeout
    assert_receive {:provider_call, ^task_pid, {:delete, _uid}}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    payload
  end

  test "still moves, sends the reminder Outlook keeps, and the toast says not all came across",
       %{lv: lv, outlook: outlook} do
    choose_calendar(lv, "#{outlook.id}:cal")

    assert [%{method: :popup, minutes_before: 10}] = await_move(lv).reminders
    assert has_element?(lv, "#calendar-toast", "Moved to Outlook")

    assert has_element?(
             lv,
             "#calendar-toast",
             "Outlook can't hold all of the event's reminders, so some were not carried."
           )
  end

  test "a move to Exchange says not all reminders came across", %{lv: lv, exchange: exchange} do
    choose_calendar(lv, "#{exchange.id}:ews")
    await_move(lv)

    assert has_element?(lv, "#calendar-toast", "Moved to Exchange")

    assert has_element?(
             lv,
             "#calendar-toast",
             "Exchange can't hold all of the event's reminders, so some were not carried."
           )
  end

  test "says nothing of reminders when the destination keeps them all", %{
    lv: lv,
    integration: integration
  } do
    choose_calendar(lv, "#{integration.id}:family")
    await_move(lv)

    assert has_element?(lv, "#calendar-toast", "Moved to Family")
    refute has_element?(lv, "#calendar-toast", "reminders")
  end
end
