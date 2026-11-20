defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceCreateTest do
  @moduledoc """
  Saving a quick-create draft on the calendar: the server checks what
  the hook sends and answers in the reply, the draft is drawn as saving
  until the calendar answers, the toast names the result, and a create
  nobody was invited to can be undone. A create with guests invites them
  and cannot be undone.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers
  import Tymeslot.Factory, only: [insert: 2]
  import Phoenix.LiveView, only: [send_update: 3]

  alias Ecto.Changeset
  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.CalendarEventDeleteWorker
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  setup %{conn: conn} do
    context = owner(conn)
    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")
    Map.merge(context, %{lv: lv, work: "#{context.integration.id}:work"})
  end

  defp lunch(work, changes \\ %{}) do
    Map.merge(
      %{
        "draft" => "d1",
        "title" => "Lunch",
        "start" => "2026-10-15T13:00",
        "end" => "2026-10-15T14:00",
        "all_day" => false,
        "calendar" => work,
        "location" => nil,
        "free" => false,
        "guests" => []
      },
      changes
    )
  end

  defp create(lv, params),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:create", params)

  # The calendar writes each create and reports what it was sent.
  defp calendar_writes do
    test_pid = self()

    Mox.stub(CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:created, event_data})
      {:ok, CreatedEvent.new(event_data.uid, provider_event_id: "g-" <> event_data.uid)}
    end)
  end

  defp calendar_refuses do
    Mox.stub(CalendarMock, :create_event, fn _event_data, _context -> {:error, :forbidden} end)
  end

  # The reload a settled create ends with drops the hook's cache first.
  defp reloaded(lv) do
    assert_push_event(lv, "calendar:events", %{reset: true, events: events}, 1_000)
    events
  end

  defp pushed(lv) do
    assert_push_event(lv, "calendar:events", %{events: events})
    events
  end

  # Answers the held write `task` and waits until the LiveView has taken the
  # answer in: the task reports to the LiveView before it exits, and the
  # LiveView hands it on to the surface with `send_update`, which the second
  # render waits behind.
  defp settled(lv, task) do
    ref = Process.monitor(task)
    send(task, {:answer, :ok})
    assert_receive {:DOWN, ^ref, :process, ^task, _reason}, 5_000
    render(lv)
    render(lv)
  end

  defp created_and_settled(lv, work, changes \\ %{}) do
    calendar_writes()
    create(lv, lunch(work, changes))
    assert_reply(lv, %{accepted: true})
    reloaded(lv)
  end

  test "a draft is accepted, drawn as saving, and written to the calendar",
       %{lv: lv, work: work} do
    test_pid = self()

    Mox.stub(CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:create_started, self(), event_data})

      receive do
        {:answer, answer} -> answer
      end
    end)

    create(lv, lunch(work, %{"location" => "Café Rose", "free" => true}))
    assert_reply(lv, %{accepted: true})

    assert %{kind: "draft", pending: true, title: "Lunch", start: "2026-10-15T13:00"} =
             Enum.find(pushed(lv), &(&1.id == "draft-d1"))

    assert_receive {:create_started, task, event_data}, 1_000
    assert event_data.summary == "Lunch"
    assert event_data.location == "Café Rose"
    assert event_data.transparency == "transparent"
    send(task, {:answer, {:ok, CreatedEvent.new(event_data.uid)}})

    events = reloaded(lv)
    refute Enum.any?(events, &(&1.id == "draft-d1"))
    assert %{kind: "event", free: true} = Enum.find(events, &(&1.title == "Lunch"))
  end

  test "the toast says when the event is, and offers Undo", %{lv: lv, work: work} do
    created_and_settled(lv, work)

    assert has_element?(lv, "#calendar-toast", "Added: Thu 15 Oct, 13:00")
    assert has_element?(lv, "#calendar-undo")
  end

  test "an all-day create's toast names the day", %{lv: lv, work: work} do
    created_and_settled(lv, work, %{
      "all_day" => true,
      "start" => "2026-10-16",
      "end" => "2026-10-17"
    })

    assert has_element?(lv, "#calendar-toast", "Added: Fri 16 Oct")
  end

  test "a create whose calendar needs reconnecting says so beside the toast", %{
    lv: lv,
    work: work,
    integration: integration
  } do
    # The calendar was flagged after the page loaded: the event lands
    # elsewhere, and only reconnecting puts the chosen calendar back.
    integration |> Changeset.change(needs_reauth: true) |> Repo.update!()

    created_and_settled(lv, work)

    assert has_element?(lv, "#calendar-toast", "Added: Thu 15 Oct, 13:00")

    assert render(lv) =~
             "Your calendar needs to be reconnected. Please reconnect it from the Integrations page."
  end

  test "a create the calendar saved with a warning shows the warning", %{lv: lv} do
    warning = "Google Calendar saved the event without a Meet link."

    send(
      lv.pid,
      {:calendar_create_result, {"d9", "Lunch"},
       {:ok, %{event: nil, invited: [], warning: warning, reauth_required: false}}}
    )

    # The LiveView hands the result to the surface, which flashes the
    # warning back to the LiveView: one render waits behind each step.
    render(lv)
    render(lv)
    html = render(lv)

    assert html =~ "Added “Lunch”."
    assert html =~ warning
    refute html =~ "Your calendar needs to be reconnected."
  end

  test "an untitled draft is created as “New event”", %{lv: lv, work: work} do
    created_and_settled(lv, work, %{"title" => "  "})

    assert_receive {:created, %{summary: "New event"}}
  end

  test "a draft the server refuses is answered with the field and why, and nothing is written",
       %{lv: lv, work: work} do
    calendar_writes()

    create(lv, lunch(work, %{"end" => "2026-10-15T12:00"}))

    assert_reply(lv, %{
      accepted: false,
      field: "end",
      error: "The event must end after it starts."
    })

    refute_receive {:created, _event_data}, 100
    assert Repo.all(ProviderCalendarEventSchema) == []
  end

  test "a draft for a calendar that takes no writes is refused", %{
    lv: lv,
    integration: integration
  } do
    calendar_writes()

    create(lv, lunch("#{integration.id}:nowhere"))

    assert_reply(lv, %{accepted: false, field: "calendar", error: "Choose one of your calendars."})

    refute_receive {:created, _event_data}, 100
  end

  test "a draft for another organiser's calendar is refused, and nothing is written", %{
    lv: lv
  } do
    calendar_writes()

    stranger =
      insert(:calendar_integration,
        is_active: true,
        provider: "google",
        calendar_list: [%{"id" => "work", "name" => "Work", "selected" => true}]
      )

    create(lv, lunch("#{stranger.id}:work"))

    assert_reply(lv, %{accepted: false, field: "calendar", error: "Choose one of your calendars."})

    refute_receive {:created, _event_data}, 100
  end

  test "a draft the rate limit refuses is answered, and nothing is written",
       %{lv: lv, user: user, work: work} do
    calendar_writes()
    for _i <- 1..30, do: RateLimiter.check(:calendar_event_edit, user.id)

    create(lv, lunch(work))

    assert_reply(lv, %{accepted: false, error: "Too many edits. Please wait a moment."})
    refute_receive {:created, _event_data}, 100
  end

  test "a create the calendar refuses drops the draft and says so", %{lv: lv, work: work} do
    calendar_refuses()

    create(lv, lunch(work))
    assert_reply(lv, %{accepted: true})

    assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"}, 1_000)
    assert has_element?(lv, "#calendar-toast", "Couldn't add “Lunch”. Please try again.")
    refute has_element?(lv, "#calendar-undo")
    assert Repo.all(ProviderCalendarEventSchema) == []
  end

  test "undo removes the event at once and tells nobody", %{lv: lv, work: work} do
    events = created_and_settled(lv, work)
    %{id: id} = Enum.find(events, &(&1.title == "Lunch"))

    lv |> element("#calendar-undo") |> render_click()

    refute Enum.any?(pushed(lv), &(&1.id == id))
    assert has_element?(lv, "#calendar-toast", "Removed “Lunch”")

    # No undo window, and nobody told.
    [job] = all_enqueued(worker: CalendarEventDeleteWorker)
    assert job.args["undoable"] == false
    assert job.args["notify_attendees"] == false

    # It is the event just created that goes.
    assert_received {:created, %{uid: uid}}
    assert job.args["uid"] == uid
  end

  # The organiser left the calendar and came back before the browser
  # confirmed the surface's removal: the answers routed meanwhile never
  # reached it.
  defp revive(lv) do
    send_update(lv.pid, CalendarSurface, id: "calendar", calendar_left: 1)
    render(lv)
    render(lv)
  end

  defp undo(lv), do: lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

  describe "a revive while a create is in flight" do
    setup do
      test_pid = self()

      Mox.stub(CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:create_started, self(), event_data})

        receive do
          :never -> :ok
        end
      end)

      :ok
    end

    test "drops the saving draft, and the same draft can be saved again", %{lv: lv, work: work} do
      create(lv, lunch(work))
      assert_reply(lv, %{accepted: true})
      assert_receive {:create_started, _task, _event_data}, 1_000

      revive(lv)

      assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
      refute Enum.any?(reloaded(lv), &(&1.id == "draft-d1"))

      create(lv, lunch(work))
      assert_reply(lv, %{accepted: true})
      assert_receive {:create_started, _task, _event_data}, 1_000
    end
  end

  describe "while the created event moves to another calendar" do
    setup %{lv: lv, work: work, integration: integration} do
      events = created_and_settled(lv, work)
      %{id: id} = Enum.find(events, &(&1.title == "Lunch"))
      test_pid = self()

      lv |> element("#calendar-canvas") |> render_hook("calendar:edit", %{"id" => id})

      Mox.stub(CalendarMock, :create_event, fn _event_data, _context ->
        send(test_pid, {:move_started, self()})

        receive do
          :release -> {:error, :provider_down}
        end
      end)

      lv
      |> form("#calendar-panel-calendar-form")
      |> render_change(%{"calendar" => "#{integration.id}:family"})

      assert_receive {:move_started, mover}, 1_000
      on_exit(fn -> send(mover, :release) end)
      :ok
    end

    test "undo of the create is held, and stays on the stack", %{lv: lv} do
      undo(lv)

      assert render(lv) =~ "moving to another calendar"
      assert all_enqueued(worker: CalendarEventDeleteWorker) == []

      undo(lv)
      assert render(lv) =~ "moving to another calendar"
      refute render(lv) =~ "Nothing to undo."
    end

    test "after a revive the move is no longer waited for, and undo removes the event",
         %{lv: lv} do
      revive(lv)
      undo(lv)

      refute render(lv) =~ "moving to another calendar"
      assert [_job] = all_enqueued(worker: CalendarEventDeleteWorker)
    end
  end

  test "undo closes the panel open on the event it removes", %{lv: lv, work: work} do
    events = created_and_settled(lv, work)
    %{id: id} = Enum.find(events, &(&1.title == "Lunch"))

    lv |> element("#calendar-canvas") |> render_hook("calendar:edit", %{"id" => id})
    assert has_element?(lv, "#calendar-panel-title[value='Lunch']")

    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

    assert [_job] = all_enqueued(worker: CalendarEventDeleteWorker)
    refute has_element?(lv, "#calendar-panel")
    assert_push_event(lv, "calendar:panel", %{open: false})
  end

  test "undo while the created event is still saving keeps the entry and says so",
       %{lv: lv, work: work} do
    events = created_and_settled(lv, work)
    %{id: id} = Enum.find(events, &(&1.title == "Lunch"))
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn _uid, _payload, _context ->
      send(test_pid, {:write_started, self()})

      receive do
        {:answer, answer} -> answer
      end
    end)

    create_move = %{"id" => id, "start" => "2026-10-15T15:00", "end" => "2026-10-15T16:00"}
    lv |> element("#calendar-canvas") |> render_hook("calendar:move", create_move)
    assert_receive {:write_started, task}, 1_000

    # The first Undo takes the move back (queued behind the running write); the
    # second reaches the create while the event is still saving.
    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})
    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})
    assert render(lv) =~ "This event is still saving. Undo once it has saved."
    assert all_enqueued(worker: CalendarEventDeleteWorker) == []

    send(task, {:answer, :ok})
    assert_receive {:write_started, task}, 1_000
    settled(lv, task)

    # The create's entry stayed on the stack.
    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})
    assert [_job] = all_enqueued(worker: CalendarEventDeleteWorker)
  end

  test "a repeating create cannot be undone, as no series-wide change can",
       %{lv: lv, work: work} do
    created_and_settled(lv, work, %{"recurrence_rule" => "FREQ=WEEKLY"})

    assert has_element?(lv, "#calendar-toast", "Added: Thu 15 Oct, 13:00")
    refute has_element?(lv, "#calendar-undo")

    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})
    assert has_element?(lv, "#calendar-toast", "Nothing to undo.")
  end

  test "the removal landing keeps the toast that said so", %{lv: lv, user: user, work: work} do
    created_and_settled(lv, work)
    lv |> element("#calendar-undo") |> render_click()

    [job] = all_enqueued(worker: CalendarEventDeleteWorker)
    send(lv.pid, {:calendar_delete_result, user.id, job.id, :deleted})
    render(lv)
    render(lv)

    assert has_element?(lv, "#calendar-toast", "Removed “Lunch”")
  end

  test "undo of an event already gone says it is too late", %{lv: lv, user: user, work: work} do
    created_and_settled(lv, work)
    Repo.delete_all(ProviderCalendarEventSchema)

    send(lv.pid, {:calendar_events_updated, user.id, []})
    reloaded(lv)

    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

    assert has_element?(
             lv,
             "#calendar-toast",
             "Too late to undo: “Lunch” has already been deleted."
           )

    assert all_enqueued(worker: CalendarEventDeleteWorker) == []
  end

  test "a create with guests invites them, says so, and cannot be undone",
       %{lv: lv, work: work} do
    events = created_and_settled(lv, work, %{"guests" => ["anna@example.com", "ben@example.com"]})

    assert %{guests: 2} = Enum.find(events, &(&1.title == "Lunch"))
    assert has_element?(lv, "#calendar-toast", "Added and invited 2 guests")
    refute has_element?(lv, "#calendar-undo")

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_calendar_invitation", "attendee_email" => "anna@example.com"}
    )

    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})
    assert has_element?(lv, "#calendar-toast", "Nothing to undo.")
  end

  test "the same draft sent twice is created once", %{lv: lv, work: work} do
    test_pid = self()

    Mox.stub(CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:create_started, self(), event_data})

      receive do
        {:answer, answer} -> answer
      end
    end)

    create(lv, lunch(work))
    assert_reply(lv, %{accepted: true})
    create(lv, lunch(work))
    assert_reply(lv, %{accepted: true})

    assert_receive {:create_started, task, event_data}, 1_000
    refute_receive {:create_started, _task, _event_data}, 100
    send(task, {:answer, {:ok, CreatedEvent.new(event_data.uid)}})
    reloaded(lv)
  end

  # The hook lost the first reply and offered Save again: the event exists,
  # so a second create would duplicate it (and invite its guests twice).
  test "a draft sent again after its create landed is not created twice", %{lv: lv, work: work} do
    events = created_and_settled(lv, work)
    assert_receive {:created, _event_data}
    assert Enum.count(events, &(&1.title == "Lunch")) == 1
    # The hook hears the draft is settled, and drops any doubt it voiced.
    assert_push_event(lv, "calendar:create-settled", %{draft: "d1"})

    create(lv, lunch(work))
    assert_reply(lv, %{accepted: true})

    refute_receive {:created, _event_data}, 100
    # The payload goes again, so the hook draws the event in its draft's place.
    assert Enum.count(pushed(lv), &(&1.title == "Lunch")) == 1
  end

  test "a draft whose create landed cannot be opened in the side panel", %{lv: lv, work: work} do
    created_and_settled(lv, work)

    lv |> element("#calendar-canvas") |> render_hook("calendar:more_options", lunch(work))

    assert_reply(lv, %{opened: false})
    refute has_element?(lv, "#calendar-panel")
  end

  test "a draft whose create failed can be saved again", %{lv: lv, work: work} do
    calendar_refuses()
    create(lv, lunch(work))
    assert_reply(lv, %{accepted: true})
    assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"}, 1_000)

    calendar_writes()
    create(lv, lunch(work))
    assert_reply(lv, %{accepted: true})
    assert_receive {:created, _event_data}, 1_000
  end

  test "a draft id the hook would not have made is refused, and nothing is written",
       %{lv: lv, work: work} do
    calendar_writes()

    for bad <- ["", "D1", "x1", "d", "d-1", "d1 ", "../d1", "d" <> String.duplicate("1", 32)] do
      create(lv, lunch(work, %{"draft" => bad}))

      assert_reply(lv, %{
        accepted: false,
        field: nil,
        error: "Couldn't add the event. Please try again."
      })
    end

    create(lv, lunch(work, %{"draft" => 7}))
    assert_reply(lv, %{accepted: false, field: nil})

    refute_receive {:created, _event_data}, 100
  end
end
