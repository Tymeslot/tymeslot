defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceImportTest do
  @moduledoc """
  Importing an `.ics` file on the calendar, end to end: a file dropped
  on the calendar or chosen from display options is read and summarised,
  importing it writes its events to the chosen calendar, and the outcome is
  reported.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Mox
  import Phoenix.LiveView, only: [send_update: 3]
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  alias Ecto.Changeset
  alias Tymeslot.Factory
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :set_mox_global
  setup :verify_on_exit!

  # The import writes from a background task; allow for a busy test machine.
  @task_timeout 5_000

  @two_events """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  BEGIN:VEVENT\r
  UID:one@example.com\r
  SUMMARY:Dentist\r
  DTSTART:20261105T090000Z\r
  DTEND:20261105T093000Z\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  UID:two@example.com\r
  SUMMARY:Standup\r
  DTSTART:20261102T090000Z\r
  DTEND:20261102T091500Z\r
  RRULE:FREQ=WEEKLY;COUNT=4\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  defp busy_message,
    do: "An import is still running. Please wait for it to finish before importing another file."

  defp open_import(lv) do
    lv |> element("#calendar-display-options > button") |> render_click()
    lv |> element("#calendar-import-ics") |> render_click()
  end

  # The file is planned in an async task once uploaded; `render_async/1`
  # waits for it.
  defp upload(lv, content, name \\ "calendar.ics") do
    lv
    |> file_input("#calendar-ics-upload", :ics_file, [
      %{name: name, content: content, type: "text/calendar"}
    ])
    |> render_upload(name)

    render_async(lv)
  end

  defp start_import(lv), do: lv |> element("#calendar-import-start") |> render_click()

  # The result reaches the surface in two hops, each a message to the
  # LiveView (the task's result, then the surface's `send_update/2`); one
  # render per hop lets both land, and one more is spare.
  defp settle(lv), do: Enum.reduce(1..3, nil, fn _hop, _html -> render(lv) end)

  defp await_task(task) do
    ref = Process.monitor(task)
    assert_receive {:DOWN, ^ref, :process, ^task, _reason}, @task_timeout
  end

  setup %{conn: conn} do
    owner(conn)
  end

  describe "the drop target" do
    test "the whole calendar takes the upload, with an overlay while a file is over it", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      [_match, ref] =
        Regex.run(~r/id="calendar-surface"[^>]*phx-drop-target="([^"]+)"/, render(lv))

      assert has_element?(lv, ~s(#calendar-ics-upload input[type=file][id="#{ref}"]))
      assert has_element?(lv, "#calendar-drop-overlay[aria-hidden='true']")
      refute has_element?(lv, "#calendar-import")
    end

    test "a file dropped with the modal closed opens it, read and summarised", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      upload(lv, @two_events, "dropped.ics")

      assert has_element?(lv, "#calendar-import")
      summary = lv |> element(~s([data-testid="calendar-import-summary"])) |> render()
      assert summary =~ "Found 2 events."
      assert summary =~ "1 of them repeats."
      assert has_element?(lv, "#calendar-import-choose", "dropped.ics")
    end
  end

  describe "from display options" do
    test "opens the modal with a button that clicks the surface's input", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)

      [_match, ref] =
        Regex.run(~r/id="calendar-ics-upload".*?<input[^>]*id="([^"]+)"/s, render(lv))

      button = lv |> element("#calendar-import-choose") |> render()
      assert button =~ ~s(type="button")
      assert button =~ "&quot;to&quot;:&quot;##{ref}&quot;"
      refute has_element?(lv, "#calendar-import label[for]")
    end

    test "the Calendars sheet opens it too, and gives way to it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:toggle_menu", %{"menu" => "calendars"})

      lv |> element("#calendar-sheet-import-ics") |> render_click()

      assert has_element?(lv, "#calendar-import")
      refute has_element?(lv, "#calendar-calendars-sheet")
    end

    test "asks for a writable calendar first when there is none", %{
      conn: conn,
      integration: integration
    } do
      Repo.update!(Changeset.change(integration, is_active: false))
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)

      assert has_element?(
               lv,
               "#calendar-import",
               "Connect a calendar Tymeslot can write to before importing events."
             )

      refute has_element?(lv, "#calendar-import-choose")
    end
  end

  describe "importing" do
    test "writes every event to the default calendar and reports the result", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, 2, fn data, context ->
        send(test_pid, {:written, data, context, self()})
        {:ok, CreatedEvent.new(data.uid)}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)

      assert_receive {:written, %{summary: "Dentist"}, context, task}, @task_timeout
      assert_receive {:written, %{summary: "Standup"} = standup, ^context, ^task}, @task_timeout
      assert context == {integration.id, user.id}
      assert standup.recurrence_rule == "FREQ=WEEKLY;COUNT=4"
      await_task(task)

      settle(lv)
      assert has_element?(lv, "#calendar-toast", "Imported 2 events.")
      assert has_element?(lv, "#calendar-import-result", "Imported 2 events.")
      refute has_element?(lv, ~s([data-testid="calendar-import-progress"]))
    end

    test "writes to the calendar picked in the modal", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, context ->
        send(test_pid, {:written, data.calendar_id, context, self()})
        {:ok, CreatedEvent.new(data.uid)}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, @two_events)

      lv
      |> form("#calendar-import-calendar")
      |> render_change(%{"calendar" => "#{integration.id}:family"})

      start_import(lv)

      assert_receive {:written, "family", context, task}, @task_timeout
      assert context == {integration.id, user.id}
      await_task(task)
    end

    test "a calendar that is not offered is never chosen, and nothing else is written", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      other = insert_other_integration()
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, context ->
        send(test_pid, {:written, data.calendar_id, context, self()})
        {:ok, CreatedEvent.new(data.uid)}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, @two_events)

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:ics_calendar", %{"calendar" => "#{other.id}:work"})

      start_import(lv)

      # The import still goes to the organiser's own default calendar.
      assert_receive {:written, "work", {integration_id, user_id}, task}, @task_timeout
      assert {integration_id, user_id} == {integration.id, user.id}
      await_task(task)
    end

    test "refuses to start once the organiser has imported too often", %{
      conn: conn,
      user: user
    } do
      expect(Tymeslot.CalendarMock, :create_event, 0, fn _data, _context -> :unreachable end)

      Enum.find(
        Stream.repeatedly(fn -> RateLimiter.check(:calendar_ics_import, user.id) end),
        &match?({:error, :rate_limited, _message}, &1)
      )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)

      assert lv |> element(~s([data-testid="calendar-import-error"])) |> render() =~
               "Too many imports."

      refute has_element?(lv, ~s([data-testid="calendar-import-progress"]))
    end

    test "closing a running import hides it; reopening shows its progress; the end is toasted",
         %{conn: conn} do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, _context ->
        send(test_pid, {:writing, self()})

        receive do
          :continue -> {:ok, CreatedEvent.new(data.uid)}
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)
      assert_receive {:writing, task}, @task_timeout

      lv |> element("#calendar-import-close") |> render_click()
      refute has_element?(lv, "#calendar-import")

      open_import(lv)
      assert has_element?(lv, ~s([data-testid="calendar-import-progress"]))
      lv |> element("#calendar-import-close") |> render_click()

      send(task, :continue)
      assert_receive {:writing, ^task}, @task_timeout
      send(task, :continue)
      await_task(task)

      settle(lv)
      assert has_element?(lv, "#calendar-toast", "Imported 2 events.")
      refute has_element?(lv, "#calendar-import")
    end

    test "reports an import that fails part-way and takes the next file", %{conn: conn} do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        send(test_pid, {:task, self()})
        exit(:timeout)
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)

      assert_receive {:task, task}, @task_timeout
      await_task(task)

      settle(lv)
      assert has_element?(lv, "#calendar-import-result", "The import could not be finished.")

      upload(lv, @two_events, "again.ics")

      assert lv |> element(~s([data-testid="calendar-import-summary"])) |> render() =~
               "Found 2 events."
    end
  end

  describe "refusals" do
    test "a file that is not an .ics", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)

      assert {:error, [[_ref, :not_accepted]]} =
               lv
               |> file_input("#calendar-ics-upload", :ics_file, [
                 %{name: "notes.txt", content: "hello", type: "text/plain"}
               ])
               |> render_upload("notes.txt")

      # The browser follows a refused file with the form's change event,
      # which LiveViewTest leaves to the test.
      lv |> form("#calendar-ics-upload") |> render_change()

      assert lv |> element(~s([data-testid="calendar-import-error"])) |> render() =~
               "Only .ics calendar files can be imported."

      refute has_element?(lv, ~s([data-testid="calendar-import-summary"]))
    end

    test "a file that is not a calendar, and nothing is written", %{conn: conn} do
      expect(Tymeslot.CalendarMock, :create_event, 0, fn _data, _context -> :unreachable end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, "this is not a calendar")

      assert lv |> element(~s([data-testid="calendar-import-error"])) |> render() =~
               "could not be read as a calendar"

      assert has_element?(lv, "#calendar-import-start[disabled]")
    end

    test "a file while an import started in another tab runs", %{conn: conn} do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, _context ->
        send(test_pid, {:writing, self()})

        receive do
          :continue -> {:ok, CreatedEvent.new(data.uid)}
        end
      end)

      {:ok, first, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(first)
      upload(first, @two_events)
      start_import(first)
      assert_receive {:writing, task}, @task_timeout

      {:ok, second, _html} = live(conn, ~p"/dashboard/calendar")
      upload(second, @two_events, "second.ics")

      assert second |> element(~s([data-testid="calendar-import-error"])) |> render() =~
               busy_message()

      refute has_element?(second, ~s([data-testid="calendar-import-summary"]))

      send(task, :continue)
      assert_receive {:writing, ^task}, @task_timeout
      send(task, :continue)
      await_task(task)
    end

    test "a file over the size limit is refused with its limit", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)

      big = String.duplicate("x", 5_000_001)

      assert {:error, [[_ref, :too_large]]} =
               lv
               |> file_input("#calendar-ics-upload", :ics_file, [
                 %{name: "big.ics", content: big, type: "text/calendar"}
               ])
               |> render_upload("big.ics")

      lv |> form("#calendar-ics-upload") |> render_change()

      assert lv |> element(~s([data-testid="calendar-import-error"])) |> render() =~
               "The file is too large."

      refute has_element?(lv, ~s([data-testid="calendar-import-summary"]))
    end

    test "a file dropped on this surface's own running import is turned away in its progress",
         %{conn: conn} do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, _context ->
        send(test_pid, {:writing, self()})

        receive do
          :continue -> {:ok, CreatedEvent.new(data.uid)}
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)
      assert_receive {:writing, task}, @task_timeout

      upload(lv, @two_events, "again.ics")

      progress = lv |> element(~s([data-testid="calendar-import-progress"])) |> render()
      assert progress =~ "Importing 0 of 2 events..."

      assert lv |> element(~s([data-testid="calendar-import-error"])) |> render() =~
               busy_message()

      refute has_element?(lv, ~s([data-testid="calendar-import-summary"]))

      send(task, :continue)
      assert_receive {:writing, ^task}, @task_timeout
      send(task, :continue)
      await_task(task)
    end
  end

  describe "while a file is being read" do
    test "closing the modal leaves nothing behind when the plan lands", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)

      lv
      |> file_input("#calendar-ics-upload", :ics_file, [
        %{name: "calendar.ics", content: @two_events, type: "text/calendar"}
      ])
      |> render_upload("calendar.ics")

      lv |> element("#calendar-import-close") |> render_click()
      render_async(lv)

      refute has_element?(lv, "#calendar-import")
      refute has_element?(lv, ~s([data-testid="calendar-import-summary"]))
    end

    test "a calendar that went while the file was read gives way to the default", %{
      conn: conn,
      integration: integration
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)

      # "Work" is the default and is what the modal opened on; it leaves the
      # account's calendar list, and a sync brings the surface up to date.
      Repo.update!(
        Changeset.change(integration,
          calendar_list: [%{"id" => "family", "name" => "Family", "selected" => true}]
        )
      )

      send_update(lv.pid, CalendarSurface,
        id: "calendar",
        action: :integration_synced
      )

      # The rail lists the account's calendars until the reload lands.
      eventually(fn -> not (render(lv) =~ ~s(aria-label="Work")) end)

      upload(lv, @two_events)

      assert lv
             |> element("#calendar-import-calendar-select option[selected]")
             |> render() =~ "#{integration.id}:family"
    end
  end

  # An active integration of another organiser, with a "work" calendar.
  defp insert_other_integration,
    do:
      Factory.insert(:calendar_integration,
        user: Factory.insert(:user),
        provider: "google",
        is_active: true,
        calendar_list: [%{"id" => "work", "name" => "Work", "selected" => true}]
      )
end
