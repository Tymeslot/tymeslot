defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceTransferTest do
  @moduledoc """
  Moving an event to another calendar from the side panel: a single event
  moves at once with a toast and Undo, a repeating one asks first and moves
  its whole series, and the calendar copy of a booking stays where it is.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Ecto.Query, only: [from: 2]
  import Mox
  import Phoenix.LiveView, only: [send_update: 3]
  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.Calendar.PanelCalendarField

  # Provider writes run in a supervised task; allow for a busy test machine.
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

    review = event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    Map.merge(context, %{lv: lv, review: review, id: "event-#{review.id}"})
  end

  defp open_panel(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:edit", %{"id" => id})

  defp choose_calendar(lv, key),
    do: lv |> form("#calendar-panel-calendar-form") |> render_change(%{"calendar" => key})

  # Collects `count` provider calls, waits for the task that made them to
  # exit, then renders twice: once for the LiveView to take the result, once
  # for the surface to apply what it was sent.
  defp await_move(lv, count) do
    calls =
      for _call <- 1..count do
        assert_receive {:provider_call, task_pid, call}, @task_timeout
        {task_pid, call}
      end

    {task_pid, _call} = hd(calls)
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    Enum.map(calls, fn {_pid, call} -> call end)
  end

  defp rows(integration_id, summary) do
    Repo.all(
      from(e in ProviderCalendarEventSchema,
        where: e.calendar_integration_id == ^integration_id and e.summary == ^summary,
        select: e.provider_calendar_id
      )
    )
  end

  test "the select offers the writable calendars, grouped by account, with the event's chosen", %{
    lv: lv,
    integration: integration,
    id: id
  } do
    open_panel(lv, id)

    assert has_element?(lv, ~s|#calendar-panel-calendar optgroup[label="Work account"]|)

    assert has_element?(
             lv,
             ~s|#calendar-panel-calendar option[value="#{integration.id}:work"][selected]|
           )

    assert has_element?(lv, ~s|#calendar-panel-calendar option[value="#{integration.id}:family"]|)
  end

  test "a single event moves at once, says where it went, and can be moved back", %{
    lv: lv,
    integration: integration,
    review: review,
    id: id
  } do
    open_panel(lv, id)
    choose_calendar(lv, "#{integration.id}:family")

    assert [{:create, _payload}, {:delete, uid}] = await_move(lv, 2)
    assert uid == review.uid
    assert rows(integration.id, "Design review") == ["family"]
    assert has_element?(lv, "#calendar-toast", "Moved to Family")
    assert has_element?(lv, "#calendar-panel", "Saved")

    lv |> element("#calendar-undo") |> render_click()

    assert [{:create, _payload}, {:delete, _uid}] = await_move(lv, 2)
    assert rows(integration.id, "Design review") == ["work"]
    assert has_element?(lv, "#calendar-toast", "Moved back to Work")
  end

  test "the panel follows the event to its new identity", %{
    lv: lv,
    integration: integration,
    review: review,
    id: id
  } do
    open_panel(lv, id)
    choose_calendar(lv, "#{integration.id}:family")
    await_move(lv, 2)

    # The original row is gone; a panel still pointing at it would be empty.
    refute Repo.get(ProviderCalendarEventSchema, review.id)

    assert has_element?(
             lv,
             ~s|#calendar-panel-calendar option[value="#{integration.id}:family"][selected]|
           )
  end

  test "a move whose original stayed behind says so and offers no undo", %{
    lv: lv,
    integration: integration,
    id: id
  } do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
      send(test_pid, {:provider_call, self(), {:delete, uid}})
      {:error, :forbidden}
    end)

    open_panel(lv, id)
    choose_calendar(lv, "#{integration.id}:family")
    await_move(lv, 2)

    assert has_element?(lv, "#calendar-toast", "the original could not be removed")
    refute has_element?(lv, "#calendar-undo")
  end

  test "a failed move puts the event back on its calendar", %{
    lv: lv,
    integration: integration,
    id: id
  } do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), {:create, payload}})
      {:error, :forbidden}
    end)

    open_panel(lv, id)
    choose_calendar(lv, "#{integration.id}:family")
    await_move(lv, 1)

    assert rows(integration.id, "Design review") == ["work"]
    assert render(lv) =~ "Could not move the event. It is still on its original calendar."

    assert has_element?(
             lv,
             ~s|#calendar-panel-calendar option[value="#{integration.id}:work"][selected]|
           )
  end

  test "a calendar the panel never offered is ignored", %{lv: lv, id: id} do
    expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> :ok end)

    open_panel(lv, id)
    choose_calendar(lv, "999999:elsewhere")

    refute_receive {:provider_call, _pid, _call}, 100
  end

  test "the calendar copy of a booking stays where it is", %{
    conn: conn,
    integration: integration
  } do
    copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)
    insert(:meeting, calendar_integration_id: integration.id, calendar_uid: copy.uid)
    expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, "event-#{copy.id}")
    choose_calendar(lv, "#{integration.id}:family")

    assert render(lv) =~ "This is a booking. Reschedule or cancel it from Bookings."
    refute_receive {:provider_call, _pid, _call}, 100
  end

  describe "a repeating event" do
    setup %{conn: conn, integration: integration} do
      standup =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          recurring_event_id: "standup-series",
          uid: "standup-series_20261014T083000Z",
          provider_event_id: "standup-series_20261014T083000Z"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_panel(lv, "event-#{standup.id}")

      %{lv: lv, standup: standup}
    end

    test "asks before moving the whole series", %{lv: lv, integration: integration} do
      expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> :ok end)

      choose_calendar(lv, "#{integration.id}:family")

      assert has_element?(
               lv,
               "#calendar-series-move",
               "Move every event in this series to Family?"
             )
    end

    test "closing the panel drops the question", %{lv: lv, integration: integration} do
      choose_calendar(lv, "#{integration.id}:family")
      assert has_element?(lv, "#calendar-series-move")

      lv |> element("#calendar-canvas") |> render_hook("panel:close", %{})

      refute has_element?(lv, "#calendar-series-move")
    end

    test "cancelling leaves the series where it was", %{lv: lv, integration: integration} do
      choose_calendar(lv, "#{integration.id}:family")
      lv |> element("#calendar-series-move-cancel") |> render_click()

      refute has_element?(lv, "#calendar-series-move")

      assert has_element?(
               lv,
               ~s|#calendar-panel-calendar option[value="#{integration.id}:work"][selected]|
             )
    end

    test "once moved, the panel closes and the toast offers no undo", %{
      lv: lv,
      standup: standup
    } do
      send_update(lv.pid, CalendarSurface,
        id: "calendar",
        action: :series_moved,
        moved_event: standup
      )

      render(lv)

      refute has_element?(lv, "#calendar-panel")
      refute has_element?(lv, "#calendar-undo")
    end
  end

  # A create that waits for the test to let it go, so a move stays in flight.
  defp hold_creates do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), {:create, payload}})

      receive do
        :release -> {:ok, CreatedEvent.new(payload.uid)}
      end
    end)
  end

  defp other_account(user) do
    insert(:calendar_integration,
      user: user,
      name: "Other account",
      provider: "google",
      is_active: true,
      calendar_list: [%{"id" => "other", "name" => "Other", "selected" => true}]
    )
  end

  defp panel_status(lv),
    do:
      lv
      |> element("#calendar-panel-status")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.text()

  describe "while a move is in flight" do
    setup %{conn: conn, user: user, id: id} do
      other = other_account(user)
      hold_creates()
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_panel(lv, id)
      choose_calendar(lv, "#{other.id}:other")
      assert_receive {:provider_call, task_pid, {:create, _payload}}, @task_timeout

      on_exit(fn -> send(task_pid, :release) end)
      %{lv: lv, other: other, task_pid: task_pid}
    end

    test "the panel says Saving and shows the destination chosen", %{lv: lv, other: other} do
      assert panel_status(lv) =~ "Saving"

      assert has_element?(
               lv,
               ~s|#calendar-panel-calendar option[value="#{other.id}:other"][selected]|
             )
    end

    test "a panel edit is refused, even across accounts", %{lv: lv} do
      lv |> element("#calendar-panel-title") |> render_blur(%{"value" => "Renamed"})

      assert panel_status(lv) =~ "moving to another calendar"
    end

    test "a drag on the grid is refused", %{lv: lv, id: id} do
      canvas = element(lv, "#calendar-canvas")

      render_hook(canvas, "calendar:move", %{
        "id" => id,
        "start" => "2026-10-15T11:00",
        "end" => "2026-10-15T12:00"
      })

      assert render(lv) =~ "moving to another calendar"
    end

    test "a delete is refused", %{lv: lv, id: id} do
      lv |> element("#calendar-canvas") |> render_hook("calendar:delete", %{"id" => id})

      assert render(lv) =~ "moving to another calendar"
      refute has_element?(lv, "#calendar-toast")
    end

    test "the preview's Busy/Free toggle is refused", %{lv: lv, id: id} do
      lv |> element("#calendar-canvas") |> render_hook("calendar:open", %{"id" => id})
      lv |> element("#calendar-preview-free") |> render_click()

      assert render(lv) =~ "moving to another calendar"
      refute has_element?(lv, "#calendar-toast")
    end

    test "another event cannot be moved meanwhile", %{lv: lv, integration: integration} do
      lunch = event(integration, "work", "Lunch", ~U[2026-10-14 12:00:00Z])
      open_panel(lv, "event-#{lunch.id}")
      choose_calendar(lv, "#{integration.id}:family")

      assert render(lv) =~ "Another event is moving. Try again in a moment."
    end
  end

  describe "undo while a move is in flight" do
    setup do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :update_event, fn uid, payload, _context ->
        send(test_pid, {:written, self(), uid, payload})
        :ok
      end)

      :ok
    end

    # Starts the move to the Family calendar and holds it until the test ends.
    defp start_held_move(lv, integration) do
      hold_creates()
      choose_calendar(lv, "#{integration.id}:family")
      assert_receive {:provider_call, task_pid, {:create, _payload}}, @task_timeout
      on_exit(fn -> send(task_pid, :release) end)
    end

    defp undo(lv), do: lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

    test "a panel change is not taken back, and stays on the stack", %{
      lv: lv,
      integration: integration,
      id: id
    } do
      open_panel(lv, id)
      lv |> element("#calendar-panel-title") |> render_blur(%{"value" => "Renamed"})
      assert_receive {:written, _writer, _uid, %{summary: "Renamed"}}, @task_timeout
      eventually(fn -> assert panel_status(lv) =~ "Saved" end)

      start_held_move(lv, integration)
      undo(lv)

      assert render(lv) =~ "moving to another calendar"
      refute_receive {:written, _writer, _uid, _payload}, 200

      # Still on the stack: asked again, it is refused again rather than gone.
      undo(lv)
      assert render(lv) =~ "moving to another calendar"
      refute render(lv) =~ "Nothing to undo."
    end

    test "a held change follows the event to its new calendar and can be undone there", %{
      lv: lv,
      integration: integration,
      id: id
    } do
      open_panel(lv, id)
      lv |> element("#calendar-panel-title") |> render_blur(%{"value" => "Renamed"})
      assert_receive {:written, _writer, _uid, %{summary: "Renamed"}}, @task_timeout
      eventually(fn -> assert panel_status(lv) =~ "Saved" end)

      hold_creates()
      choose_calendar(lv, "#{integration.id}:family")
      assert_receive {:provider_call, creator, {:create, _payload}}, @task_timeout
      undo(lv)
      assert render(lv) =~ "moving to another calendar"

      # The move lands; its own Undo is now the newest change.
      send(creator, :release)
      assert [{:delete, _uid}] = await_move(lv, 1)

      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
        send(test_pid, {:provider_call, self(), {:create, payload}})
        {:ok, CreatedEvent.new(payload.uid)}
      end)

      undo(lv)
      await_move(lv, 2)
      assert rows(integration.id, "Renamed") == ["work"]

      # Beneath it, the title change, on the event as it is now.
      undo(lv)
      assert_receive {:written, _writer, _uid, %{summary: "Design review"}}, @task_timeout
    end

    test "a drag is not taken back", %{lv: lv, integration: integration, id: id} do
      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:move", %{
        "id" => id,
        "start" => "2026-10-14T11:00",
        "end" => "2026-10-14T12:00"
      })

      # The drag must have answered before the move starts, or the move is
      # refused as overlapping a write still in flight.
      assert_receive {:written, writer, _uid, _payload}, @task_timeout
      ref = Process.monitor(writer)
      assert_receive {:DOWN, ^ref, :process, ^writer, _reason}, @task_timeout
      render(lv)
      render(lv)

      open_panel(lv, id)
      start_held_move(lv, integration)
      undo(lv)

      assert render(lv) =~ "moving to another calendar"
      refute_receive {:written, _writer, _uid, _payload}, 200
    end
  end

  test "the select shows a placeholder, not the first calendar, when the event's has no key" do
    html =
      render_component(&PanelCalendarField.calendar_field/1,
        choices: [%{key: "1:work", name: "Work", account: "Acme", colour: "calendar-1"}],
        value: nil
      )

    assert html =~ ~s|<option value="">|
    refute html =~ "selected"
  end

  describe "a refused or cancelled choice" do
    test "draws the select again with the server's value", %{conn: conn, integration: integration} do
      copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)
      insert(:meeting, calendar_integration_id: integration.id, calendar_uid: copy.uid)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_panel(lv, "event-#{copy.id}")

      assert has_element?(lv, "#calendar-panel-calendar-field-0")
      choose_calendar(lv, "#{integration.id}:family")

      refute has_element?(lv, "#calendar-panel-calendar-field-0")

      assert has_element?(
               lv,
               ~s|#calendar-panel-calendar-field-1 option[value="#{integration.id}:work"][selected]|
             )
    end

    test "a refused series choice does too", %{conn: conn, integration: integration} do
      standup =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          recurring_event_id: "standup-series",
          uid: "standup-series_20261014T083000Z",
          provider_event_id: "standup-series_20261014T083000Z"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_panel(lv, "event-#{standup.id}")
      choose_calendar(lv, "#{integration.id}:family")
      lv |> element("#calendar-series-move-cancel") |> render_click()

      assert has_element?(
               lv,
               ~s|#calendar-panel-calendar-field-1 option[value="#{integration.id}:work"][selected]|
             )
    end
  end

  test "an event moved to a hidden calendar stays in the panel, and Undo moves it back", %{
    lv: lv,
    integration: integration,
    id: id
  } do
    lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()
    open_panel(lv, id)
    choose_calendar(lv, "#{integration.id}:family")
    await_move(lv, 2)

    assert has_element?(
             lv,
             ~s|#calendar-panel-calendar option[value="#{integration.id}:family"][selected]|
           )

    assert has_element?(lv, "#calendar-toast", "Moved to Family")
    lv |> element("#calendar-undo") |> render_click()
    await_move(lv, 2)
    assert rows(integration.id, "Design review") == ["work"]
  end

  test "a move is refused while a change to the event is still saving", %{
    lv: lv,
    integration: integration,
    id: id
  } do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context ->
      send(test_pid, {:updating, self()})

      receive do
        :release -> :ok
      end
    end)

    expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> :ok end)
    open_panel(lv, id)
    lv |> element("#calendar-panel-title") |> render_blur(%{"value" => "Renamed"})
    assert_receive {:updating, writer}, @task_timeout
    choose_calendar(lv, "#{integration.id}:family")

    assert render(lv) =~ "still saving"
    send(writer, :release)
  end

  describe "a repeating event's confirmed move" do
    setup %{conn: conn, integration: integration} do
      standup =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          recurring_event_id: "standup-series",
          uid: "standup-series_20261014T083000Z",
          provider_event_id: "standup-series_20261014T083000Z"
        )

      test_pid = self()

      stub(GoogleCalendarAPIMock, :move_event, fn _integration, _from, master_id, _to ->
        send(test_pid, {:provider_call, self(), {:move_series, master_id}})

        receive do
          :release -> {:ok, %{"iCalUID" => "standup@example.com", "id" => master_id}}
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_panel(lv, "event-#{standup.id}")
      choose_calendar(lv, "#{integration.id}:family")
      lv |> element("#calendar-series-move-confirm") |> render_click()

      %{lv: lv}
    end

    test "starts the move, says so, and refuses edits meanwhile", %{lv: lv} do
      assert_receive {:provider_call, task_pid, {:move_series, "standup-series"}}, @task_timeout
      on_exit(fn -> send(task_pid, :release) end)

      assert has_element?(lv, "#calendar-toast", "Moving the series to Family")
      refute has_element?(lv, "#calendar-series-move")

      lv |> element("#calendar-panel-title") |> render_blur(%{"value" => "Renamed"})
      assert panel_status(lv) =~ "moving to another calendar"
    end
  end
end
