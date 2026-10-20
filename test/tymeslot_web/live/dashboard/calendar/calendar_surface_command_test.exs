defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceCommandTest do
  @moduledoc """
  The command bar's server half: always rendered and closed, the toolbar's
  and the phone header's search buttons, and the search its input runs
  (two characters at least, events and bookings with what the reveal needs,
  hidden calendars left out, a closed bar dropping a late answer).
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  setup %{conn: conn}, do: owner(conn)

  defp type(lv, query) do
    lv |> form("#calendar-command-form", %{q: query}) |> render_change()
    render_async(lv)
  end

  defp status(lv), do: lv |> element("#calendar-command-status") |> render()

  test "the bar is always rendered, closed, as a labelled dialog around a combobox", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-command[role='dialog'][aria-modal='true'][aria-labelledby='calendar-command-label']"
           )

    refute has_element?(lv, "#calendar-command[data-open]")
    assert has_element?(lv, "#calendar-command-label", "Search and commands")

    assert has_element?(
             lv,
             "#calendar-command-input[role='combobox'][aria-controls='calendar-command-list'][aria-autocomplete='list'][autocomplete='off'][phx-debounce='200']"
           )

    assert has_element?(lv, "#calendar-command-list[role='listbox']")
    assert has_element?(lv, "#calendar-command-instant[phx-update='ignore']")
    assert has_element?(lv, "#calendar-command-after[phx-update='ignore']")
    assert has_element?(lv, "#calendar-command [data-command-scrim]")
  end

  test "the toolbar and the phone header each have a search button that opens the bar", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-search[aria-label='Search and commands'][aria-keyshortcuts='Control+K Meta+K']"
           )

    assert lv |> element("#calendar-search") |> render() =~ "calendar:command-open"
    assert has_element?(lv, "#calendar-phone-search[aria-label='Search and commands']")
    assert lv |> element("#calendar-phone-search") |> render() =~ "calendar:command-open"
  end

  test "one character searches nothing", %{conn: conn, integration: integration} do
    event(integration, "work", "Design review", ~U[2026-10-21 10:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    type(lv, "d")

    refute has_element?(lv, "[data-command-result]")
    refute status(lv) =~ "event"
  end

  test "an event is found, with what the reveal needs", %{conn: conn, integration: integration} do
    review = event(integration, "work", "Design review", ~U[2026-10-21 10:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    type(lv, "design")

    row = "#calendar-command-events #calendar-command-row-event-#{review.id}"

    assert has_element?(
             lv,
             "#{row}[role='option'][data-reveal-ids='event-#{review.id}'][data-date='2026-10-21'][data-start-min='660'][data-all-day='false']"
           )

    assert has_element?(lv, row, "Design review")
    assert has_element?(lv, row, "Wed 21 Oct, 11:00")
    assert has_element?(lv, row, "Work")
    assert status(lv) =~ "1 event, 0 bookings"
  end

  test "a booking is found by its guest's name", %{conn: conn, user: user} do
    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        title: "Intro call",
        meeting_type: "Intro call",
        attendee_name: "Anna Novak",
        start_time: ~U[2026-10-16 13:00:00Z],
        end_time: ~U[2026-10-16 13:30:00Z]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    type(lv, "novak")

    row = "#calendar-command-bookings #calendar-command-row-booking-#{meeting.id}"

    assert has_element?(
             lv,
             "#{row}[data-reveal-ids='booking-#{meeting.id}'][data-start-min='840']"
           )

    assert has_element?(lv, row, "Anna Novak · Intro call")
    assert status(lv) =~ "0 events, 1 booking"
  end

  test "a repeating event says so", %{conn: conn, integration: integration} do
    for days <- [0, 7] do
      event(
        integration,
        "work",
        "Team sync",
        DateTime.add(~U[2026-10-15 09:00:00Z], days, :day),
        30,
        recurring_event_id: "weekly",
        provider_event_id: "weekly_#{days}"
      )
    end

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    type(lv, "team sync")

    assert has_element?(lv, "[data-command-result]", "Repeats")
    # One row for the series, not one per occurrence.
    assert lv |> render() |> String.split(~s(id="calendar-command-row-event-)) |> length() == 2
  end

  test "a hidden calendar's events are left out", %{conn: conn, integration: integration} do
    event(integration, "work", "School fete", ~U[2026-10-21 10:00:00Z])
    event(integration, "family", "School run", ~U[2026-10-21 07:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()
    type(lv, "school")

    assert has_element?(lv, "[data-command-result]", "School fete")
    refute has_element?(lv, "[data-command-result]", "School run")
  end

  test "a new query replaces the rows of the last one", %{conn: conn, integration: integration} do
    event(integration, "work", "Design review", ~U[2026-10-21 10:00:00Z])
    event(integration, "work", "Planning", ~U[2026-10-22 10:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    type(lv, "design")
    type(lv, "planning")

    assert has_element?(lv, "[data-command-result]", "Planning")
    refute has_element?(lv, "[data-command-result]", "Design review")
  end

  test "nothing found says so", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    type(lv, "zzzz")

    assert status(lv) =~ "No matches"
  end

  test "closing the bar drops a search still running", %{conn: conn, integration: integration} do
    event(integration, "work", "Design review", ~U[2026-10-21 10:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> form("#calendar-command-form", %{q: "design"}) |> render_change()
    lv |> element("#calendar-canvas") |> render_hook("calendar:command_close", %{})
    render_async(lv)

    refute has_element?(lv, "[data-command-result]")
    refute status(lv) =~ "Searching"
    assert has_element?(lv, "#calendar-command-input[value='']")
  end

  describe "CommandSearch.async/3" do
    alias TymeslotWeb.Dashboard.Calendar.CommandSearch

    defp socket(command),
      do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, command: command}}

    test "a failed search clears the rows and flags the error" do
      command = %{CommandSearch.empty() | query: "design", loading: true, events: [:old]}

      {:noreply, socket} = CommandSearch.async(:command_search, {:exit, :boom}, socket(command))

      assert %{events: [], bookings: [], loading: false, error: true} = socket.assigns.command
    end

    test "a cancelled search is not an error" do
      {:noreply, socket} =
        CommandSearch.async(
          :command_search,
          {:exit, {:shutdown, :cancel}},
          socket(%{CommandSearch.empty() | loading: true})
        )

      assert socket.assigns.command.error == false
    end

    test "an answer to an older query changes nothing" do
      command = %{CommandSearch.empty() | query: "planning", loading: true}

      {:noreply, socket} =
        CommandSearch.async(
          :command_search,
          {:ok, {"design", %{events: [], bookings: []}}},
          socket(command)
        )

      assert socket.assigns.command == command
    end
  end

  test "the canvas carries the command bar's copy", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")

    assert html =~ "Switch to %{name}"
    assert html =~ "Use compact density"
    assert html =~ "Go to %{date}"
    assert html =~ "in view any more."
  end
end
