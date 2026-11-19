defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePanelNewTest do
  @moduledoc """
  The side panel's "New event" state, opened from quick create's More
  options: nothing is saved until Create, guests are emailed only by
  "Create and invite", and once created the panel edits the new event.
  Also the edit state's Duplicate and Delete.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Mox
  import TymeslotWeb.CalendarSurfaceHelpers
  import Phoenix.LiveView, only: [send_update: 3]

  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    forward_creates(self(), :create)

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")
    Map.merge(context, %{lv: lv})
  end

  # A provider that takes the create and never answers, so the draft stays
  # saving until the test settles it.
  defp hold_creates(test_pid) do
    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), {:create, payload}})

      receive do
        :never -> :ok
      end
    end)
  end

  # Every payload the hook was sent since the last call, as event lists.
  defp drain_events(%{proxy: {ref, _topic, _pid}} = lv, acc \\ []) do
    receive do
      {^ref, {:push_event, "calendar:events", %{events: events}}} ->
        drain_events(lv, [events | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp draft_drawn?(payloads, pending?) do
    Enum.any?(payloads, fn events ->
      Enum.any?(events, &(&1.id == "draft-d1" and &1.pending == pending?))
    end)
  end

  defp await_create(lv) do
    assert_receive {:provider_call, task_pid, {:create, payload}}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    payload
  end

  defp same?(a, b), do: DateTime.compare(a, b) == :eq

  test "More options opens the New event state with what was typed, and saves nothing", %{
    lv: lv,
    integration: integration
  } do
    open_panel_draft(lv, integration)

    assert_reply(lv, %{opened: true})
    assert has_element?(lv, "#calendar-panel", "New event")

    assert has_element?(
             lv,
             ~s|#calendar-panel-new-form input[name="title"][value="Lunch with Ada"]|
           )

    assert has_element?(lv, "#calendar-panel-create", "Create")
    refute_receive {:provider_call, _pid, _call}, 100
  end

  test "the draft is drawn on the grid and follows the panel's start, keeping its length", %{
    lv: lv,
    integration: integration
  } do
    open_panel_draft(lv, integration)
    assert_push_event(lv, "calendar:events", %{events: events})

    assert %{kind: "draft", pending: false, editable: false} =
             Enum.find(events, &(&1.id == "draft-d1"))

    render_change(new_event_form(lv), %{"_target" => ["start"], "start" => "2026-10-15T15:00"})

    assert has_element?(
             lv,
             ~s|#calendar-panel-new-form input[name="end"][value="2026-10-15T16:00"]|
           )

    assert_push_event(lv, "calendar:events", %{events: moved})

    assert %{start: "2026-10-15T15:00", end: "2026-10-15T16:00"} =
             Enum.find(moved, &(&1.id == "draft-d1"))
  end

  test "Create writes the event, and the panel goes on editing it", %{
    lv: lv,
    integration: integration
  } do
    open_panel_draft(lv, integration)
    render_submit(new_event_form(lv), %{"intent" => "create", "location" => "Canteen"})

    payload = await_create(lv)
    assert same?(payload.start_time, ~U[2026-10-15 12:00:00Z])
    assert payload.location == "Canteen"

    refute has_element?(lv, "#calendar-panel-create")
    assert has_element?(lv, "#calendar-panel-calendar-form")
  end

  test "an empty title is saved as New event", %{lv: lv, integration: integration} do
    open_panel_draft(lv, integration, %{"title" => ""})
    render_submit(new_event_form(lv), %{"intent" => "create", "title" => "  "})

    assert await_create(lv).summary == "New event"
  end

  test "a guest is only added to the draft until Create and invite", %{
    lv: lv,
    integration: integration
  } do
    open_panel_draft(lv, integration)

    render_submit(new_event_form(lv), %{
      "intent" => "add_guest",
      "guest_email" => "grace@example.com"
    })

    assert has_element?(lv, "#calendar-panel-guests li", "grace@example.com")
    assert has_element?(lv, "#calendar-panel-create", "Create and invite")
    refute_enqueued(worker: EmailWorker)

    render_submit(new_event_form(lv), %{"intent" => "create"})
    await_create(lv)

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_calendar_invitation", "attendee_email" => "grace@example.com"}
    )
  end

  test "a guest typed but not added is invited on Create", %{lv: lv, integration: integration} do
    open_panel_draft(lv, integration)

    render_change(new_event_form(lv), %{"guest_email" => " Grace@Example.com "})
    assert has_element?(lv, "#calendar-panel-create", "Create and invite")

    render_submit(new_event_form(lv), %{
      "intent" => "create",
      "guest_email" => " Grace@Example.com "
    })

    assert [%{email: "grace@example.com"}] = await_create(lv).attendees

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_calendar_invitation", "attendee_email" => "grace@example.com"}
    )
  end

  test "a typed guest the draft already has is invited once", %{
    lv: lv,
    integration: integration
  } do
    open_panel_draft(lv, integration, %{"guests" => ["grace@example.com"]})

    render_submit(new_event_form(lv), %{
      "intent" => "create",
      "guest_email" => "grace@example.com"
    })

    assert [%{email: "grace@example.com"}] = await_create(lv).attendees
  end

  test "an invalid address left in the guest field stops the create and says why", %{
    lv: lv,
    integration: integration
  } do
    open_panel_draft(lv, integration)

    render_submit(new_event_form(lv), %{"intent" => "create", "guest_email" => "not-an-address"})

    refute_receive {:provider_call, _pid, _call}, 100
    assert has_element?(lv, "#calendar-panel-guests", "Enter a valid email address.")
    assert has_element?(lv, "#calendar-panel-create:not([disabled])")
  end

  test "the organiser's own address left in the guest field stops the create", %{
    lv: lv,
    integration: integration,
    user: user
  } do
    open_panel_draft(lv, integration)

    render_submit(new_event_form(lv), %{"intent" => "create", "guest_email" => user.email})

    refute_receive {:provider_call, _pid, _call}, 100

    assert has_element?(
             lv,
             "#calendar-panel-guests",
             "You're the organiser, so there's no need to invite yourself."
           )
  end

  test "the reason a draft guest is not added is said under the field, and typing clears it",
       %{lv: lv, integration: integration} do
    open_panel_draft(lv, integration, %{"guests" => ["grace@example.com"]})

    render_submit(new_event_form(lv), %{
      "intent" => "add_guest",
      "guest_email" => "grace@example.com"
    })

    assert has_element?(lv, "#calendar-panel-guests", "grace@example.com is already a guest.")
    refute has_element?(lv, "[id$='flash-group-warning']", "already a guest")

    render_change(new_event_form(lv), %{"_target" => ["guest_email"], "guest_email" => "ada@"})

    refute has_element?(lv, "#calendar-panel-guests", "already a guest")
  end

  test "Enter in a field with no guest typed creates nothing", %{lv: lv, integration: integration} do
    open_panel_draft(lv, integration)
    render_submit(new_event_form(lv), %{"intent" => "add_guest", "guest_email" => ""})

    refute_receive {:provider_call, _pid, _call}, 100
    assert has_element?(lv, "#calendar-panel-create")
  end

  test "a draft the domain refuses keeps the panel open and says why", %{
    lv: lv,
    integration: integration
  } do
    open_panel_draft(lv, integration)

    render_submit(new_event_form(lv), %{
      "intent" => "create",
      "start" => "2026-10-15T15:00",
      "end" => "2026-10-15T14:00"
    })

    refute_receive {:provider_call, _pid, _call}, 100
    assert has_element?(lv, "#calendar-panel-create")
    assert has_element?(lv, "#calendar-panel [role=status]", "Couldn't save")
  end

  test "the organiser's own address is not added as a guest", %{
    lv: lv,
    integration: integration,
    user: user
  } do
    open_panel_draft(lv, integration)
    render_submit(new_event_form(lv), %{"intent" => "add_guest", "guest_email" => user.email})

    refute has_element?(lv, "#calendar-panel-guests li")
    assert has_element?(lv, "#calendar-panel-create", "Create")
    refute has_element?(lv, "#calendar-panel-create", "invite")
  end

  test "a draft id the hook could not have made opens nothing, and says so", %{
    lv: lv,
    integration: integration
  } do
    open_panel_draft(lv, integration, %{"draft" => "x y"})

    assert_reply(lv, %{opened: false})
    refute has_element?(lv, "#calendar-panel")
  end

  test "a failed create keeps the panel open and draws the draft again", %{
    lv: lv,
    integration: integration
  } do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), {:create, payload}})
      {:error, "boom"}
    end)

    open_panel_draft(lv, integration)
    drain_events(lv)
    render_submit(new_event_form(lv), %{"intent" => "create"})
    await_create(lv)

    assert has_element?(lv, "#calendar-panel-create")
    assert has_element?(lv, "#calendar-panel [role=status]", "Couldn't save")
    assert draft_drawn?(drain_events(lv), false)
  end

  test "a create that is queued for the calendar closes the panel", %{
    lv: lv,
    integration: integration
  } do
    hold_creates(self())
    open_panel_draft(lv, integration)
    render_submit(new_event_form(lv), %{"intent" => "create"})
    assert_receive {:provider_call, _pid, {:create, _payload}}, @task_timeout

    send(
      lv.pid,
      {:calendar_create_result, {"d1", "Lunch"}, {:error, %{reason: :offline, retry: :queued}}}
    )

    render(lv)

    refute has_element?(lv, "#calendar-panel")
  end

  test "a second Create while saving makes no second provider call", %{
    lv: lv,
    integration: integration
  } do
    hold_creates(self())
    open_panel_draft(lv, integration)
    render_submit(new_event_form(lv), %{"intent" => "create"})
    assert_receive {:provider_call, _pid, {:create, _payload}}, @task_timeout

    render_submit(new_event_form(lv), %{"intent" => "create"})

    refute_receive {:provider_call, _pid, _call}, 100
  end

  test "a revive while Create is saving closes the panel, and the draft can be created again", %{
    lv: lv,
    integration: integration
  } do
    hold_creates(self())
    open_panel_draft(lv, integration)
    render_submit(new_event_form(lv), %{"intent" => "create"})
    assert_receive {:provider_call, _pid, {:create, _payload}}, @task_timeout

    # The organiser left the calendar and came back before the browser
    # confirmed the surface's removal: the create's answer never reached it.
    send_update(lv.pid, CalendarSurface, id: "calendar", calendar_left: 1)
    render(lv)

    refute has_element?(lv, "#calendar-panel")
    assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})

    open_panel_draft(lv, integration)
    render_submit(new_event_form(lv), %{"intent" => "create"})
    assert_receive {:provider_call, _pid, {:create, _payload}}, @task_timeout
  end

  test "More options for a draft that is already saving opens nothing", %{
    lv: lv,
    integration: integration
  } do
    hold_creates(self())
    canvas_push(lv, "calendar:create", panel_draft(integration))
    assert_receive {:provider_call, _pid, {:create, _payload}}, @task_timeout

    open_panel_draft(lv, integration)

    assert_reply(lv, %{opened: false})
    refute has_element?(lv, "#calendar-panel")
  end

  test "a timed draft's all-day box is unticked, and ticking it converts the times", %{
    lv: lv,
    integration: integration
  } do
    open_panel_draft(lv, integration)

    assert has_element?(lv, "#calendar-panel-new-all-day")
    refute has_element?(lv, "#calendar-panel-new-all-day[checked]")
    # A date and time is too wide for half the panel: Starts and Ends stack.
    assert has_element?(lv, "#calendar-panel-new-span.grid-cols-1")

    render_change(new_event_form(lv), %{"_target" => ["all_day"], "all_day" => "true"})

    assert has_element?(lv, "#calendar-panel-new-all-day[checked]")
    assert has_element?(lv, "#calendar-panel-new-span.grid-cols-2")
    assert has_element?(lv, ~s|#calendar-panel-new-form input[name="start"][value="2026-10-15"]|)
    assert has_element?(lv, ~s|#calendar-panel-new-form input[name="end"][value="2026-10-15"]|)
  end

  describe "in the edit state" do
    setup %{conn: conn, integration: integration} do
      review =
        event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z], 60,
          location: "Room 4",
          attendees: [%{"email" => "ada@example.com"}]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:edit", %{"id" => "event-#{review.id}"})

      %{lv: lv, review: review}
    end

    test "Duplicate creates a copy the next day without its guests, with Undo", %{lv: lv} do
      lv |> element("#calendar-panel-duplicate") |> render_click()

      payload = await_create(lv)
      assert same?(payload.start_time, ~U[2026-10-15 09:00:00Z])
      assert same?(payload.end_time, ~U[2026-10-15 10:00:00Z])
      assert payload.location == "Room 4"
      assert Map.get(payload, :attendees) in [nil, []]
      refute_enqueued(worker: EmailWorker)
      assert has_element?(lv, "#calendar-undo")
    end

    test "Duplicate of a repeating event with a call makes a single event without it", %{
      conn: conn,
      integration: integration
    } do
      weekly =
        event(integration, "work", "Weekly", ~U[2026-10-14 11:00:00Z], 60,
          recurrence_rule: "FREQ=WEEKLY",
          video_link: "https://meet.example.com/weekly"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas_push(lv, "calendar:edit", %{"id" => "event-#{weekly.id}"})
      lv |> element("#calendar-panel-duplicate") |> render_click()

      payload = await_create(lv)
      assert payload.summary == "Weekly"
      assert payload.recurrence_rule == nil
      assert Map.get(payload, :video_integration_id) == nil
    end

    test "Duplicate keeps the notes but not the old call's join line", %{
      conn: conn,
      integration: integration
    } do
      call =
        event(integration, "work", "Call", ~U[2026-10-14 11:00:00Z], 60,
          description: "Agenda\n\nJoin video call: https://meet.example.com/old",
          video_link: "https://meet.example.com/old"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas_push(lv, "calendar:edit", %{"id" => "event-#{call.id}"})
      lv |> element("#calendar-panel-duplicate") |> render_click()

      payload = await_create(lv)
      assert payload.description == "Agenda"
    end

    test "Delete hands the event to the delete flow and closes the panel", %{lv: lv} do
      lv |> element("#calendar-panel-delete") |> render_click()

      refute has_element?(lv, "#calendar-panel")
      # The event has a guest, so plan 2's delete asks whether to tell them.
      assert has_element?(lv, "#calendar-delete-confirm")
    end
  end
end
