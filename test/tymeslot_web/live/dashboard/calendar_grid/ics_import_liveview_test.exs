defmodule TymeslotWeb.Dashboard.CalendarGrid.IcsImportLiveviewTest do
  @moduledoc """
  The calendar dashboard's `.ics` import, end to end: the header button opens
  the modal, an uploaded file is summarised, and importing it writes its
  events to the chosen calendar and reports the outcome.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Security.RateLimiter

  setup :set_mox_global
  setup :verify_on_exit!

  @two_events """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  BEGIN:VEVENT\r
  UID:one@example.com\r
  SUMMARY:Dentist\r
  DTSTART:20261105T090000Z\r
  DTEND:20261105T093000Z\r
  ATTENDEE:mailto:ada@example.com\r
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

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp open_import(lv) do
    lv |> element(~s([data-testid="import-ics-button"])) |> render_click()
  end

  # The file is planned in an async task once uploaded; `render_async/1`
  # waits for it.
  defp upload(lv, content, name \\ "calendar.ics") do
    lv
    |> file_input("#import-ics-upload", :ics_file, [
      %{name: name, content: content, type: "text/calendar"}
    ])
    |> render_upload(name)

    render_async(lv)
  end

  defp busy_message,
    do: "An import is still running. Please wait for it to finish before importing another file."

  defp start_import(lv) do
    lv |> element("#import-ics-modal button", "Import") |> render_click()
  end

  # The import's result reaches the grid in three hops, each a message to the
  # LiveView: the task's result, the grid's `send_update/2`, and the flash the
  # grid sends back. A render is a call, so it is answered only after the
  # messages already queued ahead of it; one render per hop lets all three land.
  defp settle(lv), do: Enum.reduce(1..3, nil, fn _hop, _html -> render(lv) end)

  describe "with a writable calendar" do
    setup %{user: user} do
      %{integration: insert(:calendar_integration, user: user, calendar_list: [])}
    end

    test "imports every event of the file into the calendar", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, 2, fn data, context ->
        send(test_pid, {:written, data, context, self()})
        {:ok, CreatedEvent.new(data.uid)}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      assert open_import(lv) =~ ~s(data-testid="import-ics-modal")

      upload(lv, @two_events)
      summary = lv |> element(~s([data-testid="import-ics-summary"])) |> render()
      assert summary =~ "Found 2 events."
      assert summary =~ "1 of them repeats."

      start_import(lv)

      assert_receive {:written, %{summary: "Dentist"} = dentist, context, task}
      assert_receive {:written, %{summary: "Standup"} = standup, ^context, ^task}
      assert context == {integration.id, user.id}
      refute Map.has_key?(dentist, :attendees)
      assert standup.recurrence_rule == "FREQ=WEEKLY;COUNT=4"

      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      html = settle(lv)
      assert html =~ "Imported 2 events."
      refute html =~ ~s(data-testid="import-ics-modal")
    end

    test "picks a file through a button that clicks the grid's input without bubbling", %{
      conn: conn
    } do
      # A label for the input would forward its click to an element outside
      # the modal, which the modal's click-away takes for a click outside it.
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)

      [_match, ref] =
        Regex.run(~r/id="import-ics-upload".*?<input[^>]*id="([^"]+)"/s, render(lv))

      button = lv |> element("#import-ics-choose") |> render()
      assert button =~ ~s(type="button")
      assert button =~ "&quot;dispatch&quot;"
      assert button =~ "&quot;to&quot;:&quot;##{ref}&quot;"
      assert button =~ "&quot;event&quot;:&quot;click&quot;"
      refute has_element?(lv, "#import-ics-panel label[for]")
    end

    test "writes to the calendar picked in the modal", %{conn: conn, user: user} do
      picked =
        insert(:calendar_integration,
          user: user,
          calendar_list: [
            %{id: "/cal/home/", path: "/cal/home/", name: "Home", selected: true},
            %{id: "/cal/work/", path: "/cal/work/", name: "Work", selected: true}
          ]
        )

      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, context ->
        send(test_pid, {:written, data.calendar_id, context, self()})
        {:ok, CreatedEvent.new(data.uid)}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)
      upload(lv, @two_events)

      lv
      |> element(
        ~s(#import-ics-modal button[phx-value-integration-id="#{picked.id}"][phx-value-calendar-id="/cal/work/"])
      )
      |> render_click()

      start_import(lv)

      assert_receive {:written, "/cal/work/", context, task}
      assert context == {picked.id, user.id}
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}
    end

    test "refuses a calendar that is not the user's, and writes nothing", %{conn: conn} do
      other = insert(:calendar_integration, user: insert(:user), calendar_list: [])
      expect(Tymeslot.CalendarMock, :create_event, 0, fn _data, _context -> :unreachable end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)
      upload(lv, @two_events)

      lv
      |> element("#import-ics-modal [phx-click=select_ics_import_calendar]")
      |> render_click(%{"integration-id" => to_string(other.id)})

      start_import(lv)

      assert lv |> element(~s([data-testid="import-ics-error"])) |> render() =~
               "Invalid calendar selected"

      refute has_element?(lv, ~s([data-testid="import-ics-progress"]))
    end

    test "refuses a file that is not an .ics", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)

      assert {:error, [[_ref, :not_accepted]]} =
               lv
               |> file_input("#import-ics-upload", :ics_file, [
                 %{name: "notes.txt", content: "hello", type: "text/plain"}
               ])
               |> render_upload("notes.txt")

      # The browser follows a refused file with the form's change event, which
      # LiveViewTest leaves to the test.
      lv |> form("#import-ics-upload") |> render_change()

      assert lv |> element(~s([data-testid="import-ics-error"])) |> render() =~
               "Only .ics calendar files can be imported."

      refute has_element?(lv, ~s([data-testid="import-ics-summary"]))
    end

    test "refuses to start once the user has imported too often", %{conn: conn, user: user} do
      expect(Tymeslot.CalendarMock, :create_event, 0, fn _data, _context -> :unreachable end)

      Enum.find(
        Stream.repeatedly(fn -> RateLimiter.check_calendar_ics_import_rate_limit(user.id) end),
        &match?({:error, :rate_limited, _message}, &1)
      )

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)

      assert lv |> element(~s([data-testid="import-ics-error"])) |> render() =~
               "Too many imports."

      refute has_element?(lv, ~s([data-testid="import-ics-progress"]))
    end

    test "drops a file still uploading when the modal is cancelled", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)

      lv
      |> file_input("#import-ics-upload", :ics_file, [
        %{name: "calendar.ics", content: @two_events, type: "text/calendar"}
      ])
      |> render_upload("calendar.ics", 50)

      assert has_element?(lv, "#import-ics-panel", "Reading the file...")

      lv |> element("#import-ics-modal button", "Cancel") |> render_click()
      open_import(lv)

      refute has_element?(lv, "#import-ics-panel", "Reading the file...")
    end

    test "reports an import that fails part-way and takes the next file", %{conn: conn} do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        send(test_pid, {:task, self()})
        exit(:timeout)
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)

      assert_receive {:task, task}
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      html = settle(lv)
      assert html =~ "The import could not be finished."
      refute html =~ ~s(data-testid="import-ics-progress")

      upload(lv, @two_events, "again.ics")

      assert lv |> element(~s([data-testid="import-ics-summary"])) |> render() =~
               "Found 2 events."
    end

    test "says the calendar is not responding when its circuit breaker is open", %{conn: conn} do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        send(test_pid, {:task, self()})
        {:error, :circuit_open}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)

      assert_receive {:task, task}
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      assert settle(lv) =~ "The import stopped because your calendar is not responding."
    end

    test "turns a file away while an import started elsewhere runs", %{conn: conn} do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, _context ->
        send(test_pid, {:writing, self()})

        receive do
          :continue -> {:ok, CreatedEvent.new(data.uid)}
        end
      end)

      {:ok, first, _html} = live(conn, ~p"/dashboard")
      open_import(first)
      upload(first, @two_events)
      start_import(first)
      assert_receive {:writing, task}

      # Another tab, or this one after leaving the calendar and coming back.
      {:ok, second, _html} = live(conn, ~p"/dashboard")
      upload(second, @two_events, "second.ics")

      assert second |> element(~s([data-testid="import-ics-error"])) |> render() =~ busy_message()
      refute has_element?(second, ~s([data-testid="import-ics-summary"]))

      ref = Process.monitor(task)
      send(task, :continue)
      assert_receive {:writing, ^task}
      send(task, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}
    end

    test "makes the whole calendar a drop target for the import's upload", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      [_match, ref] = Regex.run(~r/id="calendar-grid"[^>]*phx-drop-target="([^"]+)"/, render(lv))

      assert has_element?(lv, ~s(#import-ics-upload input[type=file][id="#{ref}"]))
    end

    test "a file dropped on the calendar opens the import with the file read", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      refute has_element?(lv, ~s([data-testid="import-ics-modal"]))

      # A drop puts the file in the grid's own input; no button is clicked.
      upload(lv, @two_events, "dropped.ics")

      assert has_element?(lv, ~s([data-testid="import-ics-modal"]))

      assert lv |> element(~s([data-testid="import-ics-summary"])) |> render() =~
               "Found 2 events."

      assert has_element?(lv, "#import-ics-panel", "dropped.ics")
    end

    test "a file dropped while an import runs leaves that import alone", %{conn: conn} do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn data, _context ->
        send(test_pid, {:writing, self()})

        receive do
          :continue -> {:ok, CreatedEvent.new(data.uid)}
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)
      assert_receive {:writing, task}

      lv |> element("#import-ics-modal button", "Close") |> render_click()
      upload(lv, @two_events, "second.ics")

      assert has_element?(lv, ~s([data-testid="import-ics-progress"]))
      refute has_element?(lv, "#import-ics-panel")

      ref = Process.monitor(task)
      send(task, :continue)
      assert_receive {:writing, ^task}
      send(task, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      assert settle(lv) =~ "Imported 2 events."
    end

    test "says so when the file is not a calendar, and writes nothing", %{conn: conn} do
      expect(Tymeslot.CalendarMock, :create_event, 0, fn _data, _context -> :unreachable end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)
      upload(lv, "this is not a calendar")

      assert lv |> element(~s([data-testid="import-ics-error"])) |> render() =~
               "could not be read as a calendar"

      refute has_element?(lv, ~s([data-testid="import-ics-summary"]))
    end

    test "says so when a write fails, naming the event", %{conn: conn} do
      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn
        %{summary: "Dentist"}, _context ->
          send(test_pid, {:task, self()})
          {:error, :network_error}

        data, _context ->
          {:ok, CreatedEvent.new(data.uid)}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_import(lv)
      upload(lv, @two_events)
      start_import(lv)

      assert_receive {:task, task}
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      html = settle(lv)
      assert html =~ "Imported 1 event."
      assert html =~ "1 event could not be imported. (Dentist)"
    end
  end

  test "asks for a writable calendar first when there is none", %{conn: conn, user: user} do
    insert(:calendar_integration, user: user, provider: "ics_url")

    {:ok, lv, _html} = live(conn, ~p"/dashboard")
    html = open_import(lv)

    assert html =~ "Connect a calendar Tymeslot can write to before importing events."
    refute has_element?(lv, "#import-ics-panel")
  end
end
