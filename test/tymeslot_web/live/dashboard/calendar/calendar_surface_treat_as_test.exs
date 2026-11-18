defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceTreatAsTest do
  @moduledoc """
  The preview's "Treat as Busy | Free" for an all-day event on a read-only
  calendar that blocks bookings: the default follows how the calendar marks
  the event, a choice is kept in Tymeslot (never written to
  the calendar), the default's button clears it, and nothing is offered or
  accepted for any other event.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Availability.Bookability
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    context = owner(conn)
    # A change of bookability reloads the bookable layer, which reads the calendars.
    TestMocks.stub_no_calendar_events()

    holidays =
      insert(:calendar_integration,
        user: context.user,
        name: "Holidays",
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "hol", "name" => "UK holidays", "selected" => true, "read_only" => true}
        ]
      )

    holiday = all_day(holidays, "hol", "Bank holiday", transparency: "transparent")
    Map.merge(context, %{holidays: holidays, holiday: holiday})
  end

  # An all-day event on Thursday 15 October.
  defp all_day(integration, calendar_id, summary, attrs \\ []) do
    event(
      integration,
      calendar_id,
      summary,
      ~U[2026-10-15 00:00:00Z],
      60,
      Keyword.merge(
        [
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-10-15],
          end_date: ~D[2026-10-16]
        ],
        attrs
      )
    )
  end

  defp open(lv, event) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:open", %{"id" => "event-#{event.id}"})

    assert_reply(lv, %{opened: true})
  end

  defp send_choice(lv, event, busy),
    do:
      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:bookability", %{"id" => "event-#{event.id}", "busy" => busy})

  test "a read-only all-day event its calendar marks free is Free for bookings by default", %{
    conn: conn,
    holiday: holiday
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, holiday)

    assert has_element?(lv, ~s(#calendar-preview-treat-free[aria-pressed="true"]))
    assert has_element?(lv, ~s(#calendar-preview-treat-busy[aria-pressed="false"]))
    assert has_element?(lv, "#calendar-preview-treat-as", "Treat as")
    assert has_element?(lv, "#calendar-preview-treat-as", "Guests can book this time")

    assert has_element?(
             lv,
             "#calendar-preview-treat-as",
             "Affects Tymeslot bookings only. Your calendar doesn't change."
           )

    refute has_element?(lv, "#calendar-preview-busy")
  end

  test "a cancelled one follows the rule: Free by default, and Busy stores a choice", %{
    conn: conn,
    user: user,
    holidays: holidays
  } do
    called_off = all_day(holidays, "hol", "Called-off holiday", status: "cancelled")
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, called_off)

    assert has_element?(lv, ~s(#calendar-preview-treat-free[aria-pressed="true"]))
    assert has_element?(lv, "#calendar-preview-treat-as", "Guests can book this time")

    lv |> element("#calendar-preview-treat-busy") |> render_click()

    assert Bookability.for_user(user.id) == %{{holidays.id, called_off.uid} => true}
    assert has_element?(lv, ~s(#calendar-preview-treat-busy[aria-pressed="true"]))

    lv |> element("#calendar-preview-treat-free") |> render_click()

    assert Bookability.for_user(user.id) == %{}

    assert has_element?(
             lv,
             "#calendar-toast",
             "Treated as free for bookings. Guests can book this time."
           )
  end

  test "on a repeating CalDAV event the toast says the choice covers every repeat", %{
    conn: conn,
    user: user
  } do
    feed =
      insert(:calendar_integration,
        user: user,
        name: "Shared holidays",
        provider: "caldav",
        is_active: true,
        calendar_list: [
          %{"id" => "/hol/", "name" => "Shared holidays", "selected" => true, "read_only" => true}
        ]
      )

    yearly =
      all_day(feed, "/hol/", "Founders' day",
        provider: "caldav",
        transparency: "opaque",
        recurrence_rule: "FREQ=YEARLY"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, yearly)

    lv |> element("#calendar-preview-treat-free") |> render_click()

    assert Bookability.for_user(user.id) == %{{feed.id, yearly.uid} => false}

    assert has_element?(
             lv,
             "#calendar-toast",
             "Treated as free for bookings every time this repeats. Guests can book those times."
           )
  end

  test "Busy is kept in Tymeslot, and the preview and toast follow", %{
    conn: conn,
    user: user,
    holidays: holidays,
    holiday: holiday
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, holiday)

    lv |> element("#calendar-preview-treat-busy") |> render_click()

    assert Bookability.for_user(user.id) == %{{holidays.id, holiday.uid} => true}
    assert has_element?(lv, ~s(#calendar-preview-treat-busy[aria-pressed="true"]))
    assert has_element?(lv, "#calendar-preview-treat-as", "Guests can't book this time")

    assert has_element?(
             lv,
             "#calendar-toast",
             "Treated as busy for bookings. Guests can't book this time."
           )
  end

  test "Free puts a stored choice back to the default", %{
    conn: conn,
    user: user,
    holidays: holidays,
    holiday: holiday
  } do
    Bookability.set(user.id, holidays.id, holiday.uid, true)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, holiday)
    assert has_element?(lv, ~s(#calendar-preview-treat-busy[aria-pressed="true"]))

    lv |> element("#calendar-preview-treat-free") |> render_click()

    assert Bookability.for_user(user.id) == %{}
    assert has_element?(lv, ~s(#calendar-preview-treat-free[aria-pressed="true"]))

    assert has_element?(
             lv,
             "#calendar-toast",
             "Treated as free for bookings. Guests can book this time."
           )
  end

  test "an explicit Free is stored as one", %{
    conn: conn,
    user: user,
    holidays: holidays,
    holiday: holiday
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    send_choice(lv, holiday, "false")

    assert Bookability.for_user(user.id) == %{{holidays.id, holiday.uid} => false}
  end

  test "a timed event on a read-only calendar gets no control, and a push for it is ignored", %{
    conn: conn,
    user: user,
    holidays: holidays
  } do
    timed = event(holidays, "hol", "Office closed", ~U[2026-10-15 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, timed)

    refute has_element?(lv, "#calendar-preview-treat-as")

    send_choice(lv, timed, "false")
    assert Bookability.for_user(user.id) == %{}
  end

  test "an all-day event Tymeslot can write to keeps Show as instead", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    offsite = all_day(integration, "work", "Offsite")
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, offsite)

    refute has_element?(lv, "#calendar-preview-treat-as")
    assert has_element?(lv, "#calendar-preview-busy")

    send_choice(lv, offsite, "false")
    assert Bookability.for_user(user.id) == %{}
  end

  test "a read-only calendar that doesn't block bookings gets no control", %{
    conn: conn,
    user: user
  } do
    shown =
      insert(:calendar_integration,
        user: user,
        name: "Team",
        provider: "google",
        is_active: true,
        calendar_list: [
          %{
            "id" => "team",
            "name" => "Team",
            "selected" => true,
            "read_only" => true,
            "blocks_availability" => false
          }
        ]
      )

    away = all_day(shown, "team", "Sam away")
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, away)

    refute has_element?(lv, "#calendar-preview-treat-as")
    assert has_element?(lv, "#calendar-preview", "This calendar doesn't block bookings")
  end

  test "the edit rate limit stores nothing and says so", %{
    conn: conn,
    user: user,
    holiday: holiday
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, holiday)
    for _i <- 1..30, do: RateLimiter.check(:calendar_event_edit, user.id)

    lv |> element("#calendar-preview-treat-busy") |> render_click()

    assert Bookability.for_user(user.id) == %{}
    assert render(lv) =~ "Too many edits. Please wait a moment."
  end

  test "an unknown event or choice is ignored", %{conn: conn, user: user, holiday: holiday} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:bookability", %{"id" => "event-0", "busy" => "false"})

    send_choice(lv, holiday, "maybe")

    assert Bookability.for_user(user.id) == %{}
    assert has_element?(lv, "#calendar-surface")
  end
end
