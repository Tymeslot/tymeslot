defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceAgendaTest do
  @moduledoc """
  The agenda on the server: its URL, title and steps, the four weeks either
  side of its first chunk, the chunks `calendar:agenda_more` adds as the
  list scrolls, up to 24 weeks from its date, and a reload that keeps them.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import TymeslotWeb.BookableLayerHelpers
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock

  setup %{conn: conn}, do: owner(conn)

  defp open(conn) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=agenda&date=2026-10-14")
    lv
  end

  defp more(lv, params) when is_map(params),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:agenda_more", params)

  defp more(lv, through), do: more(lv, %{"through" => through})

  test "an agenda URL is titled with where it starts, and steps by four weeks", %{conn: conn} do
    lv = open(conn)

    assert lv |> element("#calendar-period-title") |> render() =~ "From Wed 14 Oct"
    assert has_element?(lv, "#calendar-prev[aria-label='Earlier']")

    lv |> element("#calendar-next") |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=agenda&date=2026-11-11")
  end

  test "its events say which Tymeslot made, for the Bookings filter", %{
    conn: conn,
    integration: integration
  } do
    made =
      event(integration, "work", "Intro call", ~U[2026-10-15 09:00:00Z], 30,
        created_by_tymeslot: true
      )

    synced = event(integration, "work", "Lunch", ~U[2026-10-15 12:00:00Z])
    lv = open(conn)
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})
    assert_reply(lv, %{events: events})

    flags = Map.new(events, &{&1.id, &1.tymeslot})
    assert flags["event-#{made.id}"] == true
    assert flags["event-#{synced.id}"] == false
  end

  test "the hook's first request gets four weeks before the agenda and eight from it", %{
    conn: conn
  } do
    lv = open(conn)
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{
      view: "agenda",
      date: "2026-10-14",
      range: %{from: "2026-09-16", to: "2026-12-09"}
    })
  end

  test "the list's end asks for the next four weeks, which come with their events", %{
    conn: conn,
    integration: integration
  } do
    event(integration, "work", "Christmas lunch", ~U[2026-12-15 12:00:00Z])
    lv = open(conn)

    more(lv, "2026-12-08")

    assert_reply(lv, %{
      done: false,
      payload: %{
        view: "agenda",
        date: "2026-10-14",
        reset: false,
        range: %{from: "2026-12-09", to: "2027-01-06"},
        events: events
      }
    })

    assert %{start: "2026-12-15T12:00"} = Enum.find(events, &(&1.title == "Christmas lunch"))
  end

  test "it goes no further than 24 weeks from its date, and says when it is done", %{
    conn: conn
  } do
    lv = open(conn)

    for through <- ~w(2026-12-08 2027-01-05 2027-02-02) do
      more(lv, through)
      assert_reply(lv, %{done: false, payload: %{}})
    end

    more(lv, "2027-03-02")
    assert_reply(lv, %{done: true, payload: %{range: %{from: "2027-03-03", to: "2027-03-31"}}})

    more(lv, "2027-03-30")
    assert_reply(lv, %{done: true, payload: nil})
  end

  test "a browser holding days past the loaded window gets four weeks past them", %{conn: conn} do
    lv = open(conn)

    more(lv, "2026-12-20")

    assert_reply(lv, %{payload: %{range: %{from: "2026-12-09", to: "2027-01-18"}}})
  end

  test "a sync reloads the whole agenda it has grown to, never less", %{conn: conn, user: user} do
    lv = open(conn)
    more(lv, "2026-12-08")
    assert_reply(lv, %{done: false})

    send(lv.pid, {:calendar_events_updated, user.id, []})

    assert_push_event(
      lv,
      "calendar:events",
      %{reset: true, range: %{from: "2026-09-16", to: "2027-01-06"}},
      1_000
    )
  end

  test "hidden calendars stay out of a chunk", %{conn: conn, integration: integration} do
    event(integration, "family", "Swimming gala", ~U[2026-12-16 10:00:00Z])
    event(integration, "work", "Year planning", ~U[2026-12-17 10:00:00Z])
    lv = open(conn)

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:toggle_calendar", %{
      "integration-id" => to_string(integration.id),
      "calendar-id" => "family"
    })

    more(lv, "2026-12-08")

    assert_reply(lv, %{payload: %{events: events}})
    titles = Enum.map(events, & &1.title)
    assert "Year planning" in titles
    refute "Swimming gala" in titles
  end

  test "a request meant for another agenda, a view that is not one, or no day, gets nothing", %{
    conn: conn
  } do
    lv = open(conn)

    more(lv, "2026-01-01")
    assert_reply(lv, %{payload: nil, done: false})

    more(lv, %{})
    assert_reply(lv, %{payload: nil, done: false})

    {:ok, week, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-14")
    more(week, "2026-10-25")
    assert_reply(week, %{payload: nil, done: false})
  end

  test "a new period starts the agenda again from its base window", %{conn: conn} do
    lv = open(conn)

    for through <- ~w(2026-12-08 2027-01-05) do
      more(lv, through)
      assert_reply(lv, %{done: false})
    end

    lv |> element("#calendar-next") |> render_click()

    assert_push_event(
      lv,
      "calendar:events",
      %{reset: false, range: %{from: "2026-10-14", to: "2027-01-06"}},
      1_000
    )
  end

  describe "with a meeting type" do
    setup %{user: user} do
      open_days(user)
      meeting_type(user)
      :ok
    end

    test "agenda computes no bookable times", %{conn: conn} do
      test_pid = self()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        send(test_pid, :fetched)
        {:ok, []}
      end)

      lv = open(conn)
      render_async(lv)

      refute_push_event(lv, "calendar:bookable", _layer)
      refute_received :fetched
    end
  end
end
