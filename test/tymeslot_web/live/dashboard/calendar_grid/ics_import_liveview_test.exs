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

  defp upload(lv, content, name \\ "calendar.ics") do
    lv
    |> file_input("#import-ics-upload", :ics_file, [
      %{name: name, content: content, type: "text/calendar"}
    ])
    |> render_upload(name)
  end

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
