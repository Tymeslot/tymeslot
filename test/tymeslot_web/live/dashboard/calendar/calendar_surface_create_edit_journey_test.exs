defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceCreateEditJourneyTest do
  @moduledoc """
  The organiser adds events on the calendar without a form: types one
  into quick create, is told when the server refuses it, opens another in
  the side panel through More options and invites a guest, then edits the
  first from the panel (a title, Free) and takes each change back with Ctrl Z,
  including the create itself. The invited event is never touched by undo.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventDeleteWorker
  alias Tymeslot.Workers.EmailWorker

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    Mox.stub(CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:created, payload})

      # Lunch is held until the test lets it go, so its draft can be seen
      # saving.
      if payload.summary == "Lunch with Sam" do
        send(test_pid, {:holding, self()})

        receive do
          :release -> :ok
        end
      end

      {:ok, CreatedEvent.new(payload.uid, provider_event_id: "g-" <> payload.uid)}
    end)

    Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:written, uid, payload})
      :ok
    end)

    Mox.stub(CalendarMock, :delete_event, fn uid, _context, _opts ->
      send(test_pid, {:deleted, uid})
      :ok
    end)

    # The sync job the writes leave behind finds nothing new at the provider.
    Mox.stub(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: [], next_sync_token: "next"}}
    end)

    # Its sweep lists what the calendar holds, which is what the cache holds.
    Mox.stub(GoogleCalendarAPIMock, :list_events, fn integration, calendar, _from, _to ->
      rows =
        Repo.all(
          from(e in ProviderCalendarEventSchema,
            where:
              e.calendar_integration_id == ^integration.id and e.provider_calendar_id == ^calendar
          )
        )

      {:ok, Enum.map(rows, &google_event/1)}
    end)

    context
  end

  defp google_event(row) do
    %{
      "id" => row.uid,
      "iCalUID" => row.uid,
      "status" => "confirmed",
      "summary" => row.summary,
      "start" => %{"dateTime" => DateTime.to_iso8601(row.start_at)},
      "end" => %{"dateTime" => DateTime.to_iso8601(row.end_at)}
    }
  end

  # Whatever the grid was pushed before this step is not this step's answer.
  defp flush_pushes do
    receive do
      {_ref, {:push_event, _event, _payload}} -> flush_pushes()
    after
      50 -> :ok
    end
  end

  defp hook(lv, name, params) do
    flush_pushes()
    lv |> element("#calendar-canvas") |> render_hook(name, params)
  end

  # The window as the grid ends up holding it: the last push of a step.
  defp last_pushed(lv, last \\ nil) do
    receive do
      {_ref, {:push_event, "calendar:events", %{events: events}}} ->
        last_pushed(lv, events)
    after
      if(last, do: 150, else: 1_000) -> last || flunk("the grid was not sent the window")
    end
  end

  defp settle(lv) do
    render(lv)
    render(lv)
  end

  defp status(lv),
    do:
      lv
      |> element("#calendar-panel-status")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.text()

  defp draft(work, changes) do
    Map.merge(
      %{
        "draft" => "d1",
        "title" => "Lunch with Sam",
        "start" => "2026-10-15T13:00",
        "end" => "2026-10-15T14:00",
        "all_day" => false,
        "calendar" => work,
        "location" => "Nero",
        "guests" => [],
        "free" => false
      },
      changes
    )
  end

  defp titled(events, title), do: Enum.find(events, &(&1.title == title))

  test "type to create, more options, edit in the panel, free, undo", %{
    conn: conn,
    integration: integration
  } do
    work = "#{integration.id}:work"
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    # 1. Type to create: the draft is drawn as saving, the provider is sent
    # what was typed, and the real event replaces the draft with an Undo.
    hook(lv, "calendar:create", draft(work, %{}))
    assert_reply(lv, %{accepted: true})

    assert_receive {:created, sent}, 2_000
    assert sent.summary == "Lunch with Sam"
    assert sent.location == "Nero"
    assert sent.transparency == "opaque"

    # Until the provider answers, the grid holds the draft, drawn as saving.
    assert_receive {:holding, task}, 2_000

    assert %{kind: "draft", pending: true} =
             draft_event = titled(last_pushed(lv), "Lunch with Sam")

    assert draft_event.id == "draft-d1"
    send(task, :release)

    events = last_pushed(lv)
    assert %{id: id, free: false} = titled(events, "Lunch with Sam")
    refute Enum.any?(events, &(&1.id == "draft-d1"))
    assert id != "draft-d1"
    settle(lv)
    assert has_element?(lv, "#calendar-toast", "Added: Thu 15 Oct, 13:00")
    assert has_element?(lv, "#calendar-undo")
    lunch_uid = sent.uid

    # The jobs the create left behind (a sync) all succeed.
    assert %{failure: 0} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)

    # 2. A refusal keeps the draft open and writes nothing.
    hook(lv, "calendar:create", draft(work, %{"draft" => "d2", "end" => "2026-10-15T12:00"}))

    assert_reply(lv, %{
      accepted: false,
      field: "end",
      error: "The event must end after it starts."
    })

    refute_receive {:created, _payload}, 100

    # 3. More options opens the New event state with what was typed, and the
    # invitation goes out only on "Create and invite".
    hook(
      lv,
      "calendar:more_options",
      draft(work, %{
        "draft" => "d3",
        "title" => "Planning",
        "start" => "2026-10-16T10:00",
        "end" => "2026-10-16T11:00",
        "location" => "",
        "guests" => ["anna@example.com"]
      })
    )

    assert_reply(lv, %{opened: true})
    assert has_element?(lv, "#calendar-panel-heading", "New event")
    assert has_element?(lv, ~s|#calendar-panel-new-form input[name="title"][value="Planning"]|)
    assert has_element?(lv, "#calendar-panel-create", "Create and invite")
    refute_enqueued(worker: EmailWorker)

    lv |> form("#calendar-panel-new-form") |> render_submit(%{"intent" => "create"})

    assert_receive {:created, planning}, 2_000
    assert planning.summary == "Planning"
    assert [%{email: "anna@example.com"}] = planning.attendees

    eventually(fn ->
      settle(lv)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "attendee_email" => "anna@example.com"}
      )
    end)

    eventually(fn ->
      settle(lv)
      assert has_element?(lv, "#calendar-toast", "Added and invited 1 guest")
    end)

    refute has_element?(lv, "#calendar-undo")

    # 4. Edit Lunch in the panel: the title is written, the header says Saved.
    hook(lv, "calendar:edit", %{"id" => id})
    assert has_element?(lv, "#calendar-panel-title")

    lv
    |> element("#calendar-panel-title")
    |> render_blur(%{"value" => "Lunch with Sam and Jo"})

    assert_receive {:written, ^lunch_uid, %{summary: "Lunch with Sam and Jo"}}, 2_000
    eventually(fn -> assert status(lv) =~ "Saved" end)
    refute status(lv) =~ "Saving"

    # 5. Free: written as transparent, and the grid draws the event as free.
    flush_pushes()
    lv |> element("#calendar-panel-free-free") |> render_click()

    assert_receive {:written, ^lunch_uid, %{transparency: "transparent"}}, 2_000
    settle(lv)
    assert %{free: true} = titled(last_pushed(lv), "Lunch with Sam and Jo")

    # 6. Ctrl Z takes back Free, then the new title.
    hook(lv, "calendar:undo", %{})
    assert_receive {:written, ^lunch_uid, %{transparency: "opaque"}}, 2_000
    settle(lv)
    assert %{free: false} = titled(last_pushed(lv), "Lunch with Sam and Jo")

    hook(lv, "calendar:undo", %{})
    assert_receive {:written, ^lunch_uid, %{summary: "Lunch with Sam"}}, 2_000
    settle(lv)
    assert titled(last_pushed(lv), "Lunch with Sam")

    # 7. Ctrl Z again takes back the create: it was made without guests, so
    # the event is deleted at once. Planning, which invited Anna, stays.
    hook(lv, "calendar:undo", %{})
    assert has_element?(lv, "#calendar-toast", "Removed “Lunch with Sam”")
    planning_uid = planning.uid

    # Only the undone create is queued for deletion, and without telling anyone.
    assert [job] = all_enqueued(worker: CalendarEventDeleteWorker)
    assert job.args["uid"] == lunch_uid
    assert job.args["notify_attendees"] == false
    assert %{failure: 0} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)
    assert_received {:deleted, ^lunch_uid}
    refute_received {:deleted, ^planning_uid}

    events = last_pushed(lv)
    refute titled(events, "Lunch with Sam")
    assert %{id: planning_id} = titled(events, "Planning")
    assert Repo.get(ProviderCalendarEventSchema, String.replace_prefix(planning_id, "event-", ""))

    # 8. Closing the panel keeps the text typed in the focused field.
    hook(lv, "calendar:edit", %{"id" => planning_id})

    hook(lv, "panel:close", %{"field" => "location", "value" => "Room 2"})
    assert_receive {:written, ^planning_uid, %{location: "Room 2"}}, 2_000
    refute has_element?(lv, "#calendar-panel")
  end
end
