defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceDeleteNoticesTest do
  @moduledoc """
  What the calendar says once a delete has run but left someone untold: a
  linked meeting that could not be cancelled, attendees a cancellation could
  not reach, and a delete queued for the next sync that was meant to tell
  them.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Workers.CalendarEventDeleteWorker

  setup %{conn: conn}, do: owner(conn)

  defp canvas(lv, name, params),
    do: lv |> element("#calendar-canvas") |> render_hook(name, params)

  defp pushed_ids(lv) do
    assert_push_event(lv, "calendar:events", %{events: events})
    Enum.map(events, & &1.id)
  end

  defp ready_ids(lv) do
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{"tab" => nil})
    assert_reply(lv, %{events: events})
    Enum.map(events, & &1.id)
  end

  defp dentist(%{conn: conn, integration: integration}) do
    dentist = event(integration, "work", "Dentist", ~U[2026-10-15 14:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    {lv, dentist, "event-#{dentist.id}"}
  end

  defp told_call(%{conn: conn, integration: integration}) do
    call =
      event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
        attendees: [%{"email" => "ada@example.com"}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    canvas(lv, "calendar:delete", %{"id" => "event-#{call.id}"})
    lv |> element("#calendar-delete-notify") |> render_click()
    pushed_ids(lv)
    [job] = all_enqueued(worker: CalendarEventDeleteWorker)
    {lv, job}
  end

  # The surface hears the result, reloads (the push waited for here) and
  # sends its LiveView the flash, which the next render shows.
  defp settled_html(lv) do
    pushed_ids(lv)
    render(lv)
  end

  test "a delete whose linked meeting could not be cancelled says so", context do
    {lv, job} = told_call(context)

    send(lv.pid, {:calendar_delete_result, context.user.id, job.id, {:deleted, :cancel_failed}})

    assert settled_html(lv) =~
             "Event deleted, but meeting cancellation failed. The attendee may not be notified."

    refute has_element?(lv, "#calendar-toast", "Deleted “Intro call”")
  end

  test "a delete whose cancellation could not be sent says the attendees were not told",
       context do
    {lv, job} = told_call(context)

    send(
      lv.pid,
      {:calendar_delete_result, context.user.id, job.id, {:deleted, :attendees_not_notified}}
    )

    assert settled_html(lv) =~ "Event deleted, but the attendees could not be notified."
    refute has_element?(lv, "#calendar-toast", "Deleted “Intro call”")
  end

  test "a queued delete that was meant to tell the guests says they have not been told",
       context do
    {lv, job} = told_call(context)

    send(lv.pid, {:calendar_delete_result, context.user.id, job.id, {:queued, :forbidden}})

    assert settled_html(lv) =~
             "Delete failed - queued to retry on next sync. Attendees have not been notified."
  end

  test "a queued delete that told nobody does not mention the attendees", context do
    {lv, _dentist, id} = dentist(context)
    canvas(lv, "calendar:delete", %{"id" => id})
    pushed_ids(lv)
    [job] = all_enqueued(worker: CalendarEventDeleteWorker)

    send(lv.pid, {:calendar_delete_result, context.user.id, job.id, {:queued, :forbidden}})

    html = settled_html(lv)
    assert html =~ "Delete failed - queued to retry on next sync"
    refute html =~ "Attendees have not been notified."
  end

  test "a queued delete reloaded from its job still knows it was meant to tell the guests",
       %{conn: conn} = context do
    {_lv, job} = told_call(context)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    ready_ids(lv)
    send(lv.pid, {:calendar_delete_result, context.user.id, job.id, {:queued, :forbidden}})

    assert settled_html(lv) =~ "Attendees have not been notified."
  end

  test "another tab says a queued delete meant to tell the guests has not told them",
       %{
         conn: conn,
         integration: integration
       } = context do
    call =
      event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
        attendees: [%{"email" => "ada@example.com"}]
      )

    {:ok, tab_b, _html} = live(conn, ~p"/dashboard/calendar")
    ready_ids(tab_b)

    {:ok, tab_a, _html} = live(conn, ~p"/dashboard/calendar")
    canvas(tab_a, "calendar:delete", %{"id" => "event-#{call.id}"})
    tab_a |> element("#calendar-delete-notify") |> render_click()
    [job] = all_enqueued(worker: CalendarEventDeleteWorker)

    # Tab B hides the event once it hears of the delete.
    pushed_ids(tab_b)
    send(tab_b.pid, {:calendar_delete_result, context.user.id, job.id, {:queued, :forbidden}})

    assert settled_html(tab_b) =~
             "Delete failed - queued to retry on next sync. Attendees have not been notified."
  end
end
