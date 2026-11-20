defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceGuestUpdateHoldTest do
  @moduledoc """
  The update "Tell guests" sends is held for a while before it goes out: the
  side panel says the guests will be told and offers Cancel meanwhile, in a
  panel opened on the event later too, until the update has gone out.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Phoenix.LiveView, only: [send_update: 3]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.Meetings.AttendeeNotifications.Dispatcher
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  setup %{conn: conn} do
    context = owner(conn)
    stub(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context -> :ok end)

    review =
      event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z], 60,
        attendees: [%{"email" => "ada@example.com", "display_name" => "Ada Lovelace"}]
      )

    lv = open_panel(context.conn, review)
    Map.merge(context, %{lv: lv, review: review})
  end

  defp open_panel(conn, event) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{event.id}"})

    lv
  end

  defp theirs(integration),
    do:
      event(integration, "work", "Their standup", ~U[2026-10-15 09:00:00Z], 30,
        organiser: %{"email" => "boss@elsewhere.example"},
        attendees: [%{"email" => "boss@elsewhere.example"}, %{"email" => "ada@example.com"}]
      )

  defp nothing_sent do
    assert all_enqueued(worker: Worker) == []
    assert all_enqueued(worker: EmailWorker) == []
  end

  defp change_and_tell(lv, review, location \\ "Room 9") do
    review |> Changeset.change(location: location) |> Repo.update!()
    send_update(lv.pid, CalendarSurface, id: "calendar", action: :events_updated)
    send_update(lv.pid, CalendarSurface, id: "calendar", action: :reload)
    lv |> element("#calendar-panel-tell-guests") |> render_click()
  end

  test "after Tell guests the panel says they will be told and offers Cancel", %{
    lv: lv,
    review: review
  } do
    change_and_tell(lv, review)

    assert has_element?(
             lv,
             "#calendar-panel-guests-pending",
             "Guests will be told about these changes"
           )

    assert has_element?(lv, "#calendar-panel-cancel-guest-update")
  end

  test "Cancel drops the update and the changes are untold again", %{lv: lv, review: review} do
    change_and_tell(lv, review)

    lv |> element("#calendar-panel-cancel-guest-update") |> render_click()

    nothing_sent()
    refute has_element?(lv, "#calendar-panel-guests-pending")
    assert has_element?(lv, "#calendar-panel-untold", "Guests haven't been told")
    assert has_element?(lv, "#calendar-toast", "Guests won't be told.")
  end

  test "Cancel in a panel reopened during the hold offers Tell guests again", %{
    lv: lv,
    review: review
  } do
    change_and_tell(lv, review)
    lv |> element("#calendar-panel-close") |> render_click()

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{review.id}"})

    refute has_element?(lv, "#calendar-panel-untold")
    lv |> element("#calendar-panel-cancel-guest-update") |> render_click()

    nothing_sent()
    assert has_element?(lv, "#calendar-panel-untold", "Guests haven't been told")
    assert has_element?(lv, "#calendar-panel-tell-guests")
  end

  test "a hold that ended while the panel was closed leaves nothing behind for a later one", %{
    lv: lv,
    review: review
  } do
    change_and_tell(lv, review)
    close_and_reopen(lv, review)
    Oban.drain_queue(queue: :emails, with_scheduled: true)

    # Reopened with nothing held: where the sent update counted from is gone.
    close_and_reopen(lv, review)
    refute has_element?(lv, "#calendar-panel-guests-pending")

    # A new hold, from another tab, cancelled here counts from the event as
    # it is, so nothing is untold: the change was told already.
    {:ok, :scheduled} = Dispatcher.schedule_update(review.id, :provider_calendar_event)
    close_and_reopen(lv, review)
    lv |> element("#calendar-panel-cancel-guest-update") |> render_click()

    assert has_element?(lv, "#calendar-toast", "Guests won't be told.")
    refute has_element?(lv, "#calendar-panel-untold")
  end

  defp close_and_reopen(lv, review) do
    lv |> element("#calendar-panel-close") |> render_click()

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{review.id}"})
  end

  test "the panel reopened on the event still offers Cancel", %{
    conn: conn,
    lv: lv,
    review: review
  } do
    change_and_tell(lv, review)

    lv2 = open_panel(conn, review)
    assert has_element?(lv2, "#calendar-panel-guests-pending")
  end

  test "a panel opened read only once seats are booked offers no Cancel", %{
    conn: conn,
    user: user,
    lv: lv,
    review: review
  } do
    change_and_tell(lv, review)

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        capacity: 3,
        calendar_uid: review.uid
      )

    insert(:participant, meeting: meeting)

    lv2 = open_panel(conn, review)
    assert has_element?(lv2, "#calendar-panel-read-only")
    refute has_element?(lv2, "#calendar-panel-guests-pending")
    refute has_element?(lv2, "#calendar-panel-cancel-guest-update")
  end

  test "a look the panel no longer waits for changes nothing", %{lv: lv, review: review} do
    change_and_tell(lv, review)
    Oban.drain_queue(queue: :emails, with_scheduled: true)
    assert all_enqueued(worker: Worker) == []

    # The panel set a watch of its own; one from an earlier Tell or panel
    # is stale and is not acted on.
    send_update(lv.pid, CalendarSurface,
      id: "calendar",
      action: :guests_pending_due,
      event_id: "event-#{review.id}",
      watch: -1,
      backoff: 1_000
    )

    assert has_element?(lv, "#calendar-panel-guests-pending")
  end

  test "an overdue update is looked at again later each time", %{
    conn: conn,
    lv: lv,
    review: review
  } do
    change_and_tell(lv, review)
    Repo.update_all(Oban.Job, set: [scheduled_at: DateTime.add(DateTime.utc_now(), -60)])
    lv2 = open_panel(conn, review)
    :erlang.trace(lv2.pid, true, [:receive])

    # Overdue and still waiting: a second, then two.
    assert_receive {:trace, _pid, :receive,
                    {:phoenix, :send_update,
                     {_ref, %{action: :guests_pending_due, backoff: 1_000}}}},
                   3_000

    assert_receive {:trace, _pid, :receive,
                    {:phoenix, :send_update,
                     {_ref, %{action: :guests_pending_due, backoff: 2_000}}}},
                   4_000

    assert has_element?(lv2, "#calendar-panel-guests-pending")
  end

  test "Cancel after the update has gone out says it is too late", %{lv: lv, review: review} do
    change_and_tell(lv, review)
    Oban.drain_queue(queue: :emails, with_scheduled: true)

    lv |> element("#calendar-panel-cancel-guest-update") |> render_click()

    assert has_element?(lv, "#calendar-toast", "Too late to cancel: guests have been told.")
    refute has_element?(lv, "#calendar-toast", "Guests won't be told.")
    refute has_element?(lv, "#calendar-panel-guests-pending")
    refute has_element?(lv, "#calendar-panel-untold")
  end

  test "Cancel after another tab cancelled it says it is no longer waiting", %{
    lv: lv,
    review: review
  } do
    change_and_tell(lv, review)

    {:ok, :cancelled} =
      Dispatcher.cancel_pending(review.id, :provider_calendar_event, due(review))

    lv |> element("#calendar-panel-cancel-guest-update") |> render_click()

    assert has_element?(lv, "#calendar-toast", "This update is no longer waiting to be sent.")
    refute has_element?(lv, "#calendar-toast", "Too late to cancel")
    assert has_element?(lv, "#calendar-panel-untold", "Guests haven't been told")
  end

  # Told at t0 (out at t0+2m), told again at t0+5m, that second hold
  # cancelled in another tab: the update that went out at t0+2m told the
  # guests nothing about the second change.
  test "Cancel after another tab cancelled a later hold does not count an earlier update", %{
    lv: lv,
    review: review
  } do
    change_and_tell(lv, review)
    two_minutes_ago = DateTime.add(DateTime.utc_now(), -120)

    Repo.update_all(Oban.Job,
      set: [
        state: "completed",
        scheduled_at: DateTime.add(two_minutes_ago, -1),
        attempted_at: two_minutes_ago,
        completed_at: two_minutes_ago
      ]
    )

    close_and_reopen(lv, review)
    change_and_tell(lv, review, "Room 10")

    {:ok, :cancelled} =
      Dispatcher.cancel_pending(review.id, :provider_calendar_event, due(review))

    lv |> element("#calendar-panel-cancel-guest-update") |> render_click()

    refute has_element?(lv, "#calendar-toast", "Too late to cancel")
    assert has_element?(lv, "#calendar-toast", "This update is no longer waiting to be sent.")
    assert has_element?(lv, "#calendar-panel-untold", "Guests haven't been told")
    assert has_element?(lv, "#calendar-panel-tell-guests")
  end

  defp due(event), do: Dispatcher.pending_due_at(event.id, :provider_calendar_event)

  test "a panel opened on a held update drops its Cancel once the update is due", %{
    conn: conn,
    lv: lv,
    review: review
  } do
    change_and_tell(lv, review)

    # The hold is over already, so the reopened panel looks again at once.
    Repo.update_all(Oban.Job, set: [scheduled_at: DateTime.add(DateTime.utc_now(), -60)])
    lv2 = open_panel(conn, review)
    :erlang.trace(lv2.pid, true, [:receive])
    assert has_element?(lv2, "#calendar-panel-guests-pending")

    Oban.drain_queue(queue: :emails, with_scheduled: true)

    await_recheck(lv2, 3)
    refute has_element?(lv2, "#calendar-panel-guests-pending")
  end

  # The panel looks again when the hold is due, and once more a second
  # later while the update has not gone out yet.
  defp await_recheck(lv, tries) do
    assert_receive {:trace, _pid, :receive,
                    {:phoenix, :send_update, {_ref, %{action: :guests_pending_due}}}},
                   3_000

    if tries > 1 and has_element?(lv, "#calendar-panel-guests-pending"),
      do: await_recheck(lv, tries - 1)
  end

  test "a forced Cancel on an event someone else organises keeps the update", %{
    conn: conn,
    integration: integration
  } do
    their = theirs(integration)
    {:ok, :scheduled} = Dispatcher.schedule_update(their.id, :provider_calendar_event)

    lv = open_panel(conn, their)
    refute has_element?(lv, "#calendar-panel-guests-pending")

    lv |> element("#calendar-canvas") |> render_hook("panel:cancel_guest_update", %{})

    assert has_element?(lv, "#app-flash-group", "Someone else organises this event")
    assert_enqueued(worker: Worker, args: %{"event_id" => their.id})
  end
end
