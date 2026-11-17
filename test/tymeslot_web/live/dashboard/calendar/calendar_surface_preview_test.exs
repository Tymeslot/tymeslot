defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePreviewTest do
  @moduledoc """
  The preview that opens when an event on the grid is clicked: calendar
  and account, time with how far away it is, place, guests, whether guests
  can book over it, and whether it is still waiting to sync. Read only in
  this release.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  setup %{conn: conn}, do: owner(conn)

  defp open(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:open", %{"id" => id})

  test "shows the calendar, time, place, guests and what it means for bookings", %{
    conn: conn,
    integration: integration
  } do
    review =
      event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z], 60,
        location: "Room 4",
        attendees: [%{"email" => "ada@example.com", "display_name" => "Ada Lovelace"}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{review.id}")

    assert_reply(lv, %{opened: true})
    assert has_element?(lv, "#calendar-preview #calendar-preview-title", "Design review")
    assert has_element?(lv, "#calendar-preview", "Work · Work account")
    assert has_element?(lv, "#calendar-preview", "Wed 14 Oct, 10:00–11:00")
    assert has_element?(lv, "#calendar-preview", "in 1 h")
    assert has_element?(lv, "#calendar-preview", "Room 4")
    assert has_element?(lv, "#calendar-preview", "Ada Lovelace")
    assert has_element?(lv, "#calendar-preview", "Guests can't book this time")
  end

  test "a free event says guests can book over it", %{conn: conn, integration: integration} do
    focus =
      event(integration, "work", "Focus time", ~U[2026-10-15 09:00:00Z], 120,
        transparency: "transparent"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open(lv, "event-#{focus.id}")

    assert has_element?(lv, "#calendar-preview", "Guests can book this time")
  end

  test "a booking leads with the guest's name and names its meeting type", %{
    conn: conn,
    user: user
  } do
    meeting =
      insert(:meeting,
        organizer_user: user,
        title: "Intro call with Anna Kowalski",
        meeting_type: "Intro call",
        attendee_name: "Anna Kowalski",
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 10:30:00Z],
        status: "confirmed"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "booking-#{meeting.id}")

    assert has_element?(lv, "#calendar-preview-title", "Anna Kowalski · Intro call")
    assert has_element?(lv, "#calendar-preview", "Tymeslot booking")
  end

  test "a booking with a calendar copy is drawn once, as the booking, naming the copy's calendar",
       %{conn: conn, user: user, integration: integration} do
    copy =
      event(integration, "work", "Intro call with Anna Kowalski", ~U[2026-10-15 10:00:00Z], 30)

    meeting =
      insert(:meeting,
        organizer_user: user,
        title: "Intro call with Anna Kowalski",
        meeting_type: "Intro call",
        attendee_name: "Anna Kowalski",
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 10:30:00Z],
        status: "confirmed",
        calendar_integration_id: integration.id,
        calendar_uid: copy.uid
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})
    assert_reply(lv, %{events: events})

    ids = Enum.map(events, & &1.id)
    assert "booking-#{meeting.id}" in ids
    refute "event-#{copy.id}" in ids

    open(lv, "event-#{copy.id}")
    assert_reply(lv, %{opened: false})

    open(lv, "booking-#{meeting.id}")
    assert has_element?(lv, "#calendar-preview", "Tymeslot booking · Work")
  end

  test "an event waiting to sync says where it is waiting to go", %{
    conn: conn,
    integration: integration
  } do
    dentist =
      event(integration, "family", "Dentist", ~U[2026-10-16 14:00:00Z], 30,
        sync_state: "locally_modified"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open(lv, "event-#{dentist.id}")

    assert has_element?(lv, "#calendar-preview", "Saved here, waiting to reach Work account")
  end

  test "a video link becomes a Join link, and only a web address does", %{
    conn: conn,
    integration: integration
  } do
    call =
      event(integration, "work", "Call", ~U[2026-10-15 13:00:00Z], 30,
        video_link: "https://meet.example.com/abc"
      )

    odd =
      event(integration, "work", "Odd", ~U[2026-10-15 15:00:00Z], 30,
        video_link: "javascript:alert(1)"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open(lv, "event-#{call.id}")
    assert has_element?(lv, "#calendar-preview a[href='https://meet.example.com/abc']", "Join")

    open(lv, "event-#{odd.id}")
    refute has_element?(lv, "#calendar-preview a")
  end

  test "an id the grid did not load opens nothing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open(lv, "event-999999999")

    assert_reply(lv, %{opened: false})
    refute has_element?(lv, "#calendar-preview")
  end

  test "the Close button hands focus back to the event", %{
    conn: conn,
    integration: integration
  } do
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{review.id}")

    lv |> element("#calendar-preview button[aria-label='Close']") |> render_click()

    refute has_element?(lv, "#calendar-preview")
    assert_push_event(lv, "calendar:preview-closed", %{})
  end

  test "Escape closes the preview and hands focus back", %{conn: conn, integration: integration} do
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{review.id}")

    lv |> element("#calendar-preview") |> render_keydown(%{"key" => "Escape"})

    refute has_element?(lv, "#calendar-preview")
    assert_push_event(lv, "calendar:preview-closed", %{})
  end

  for menu <- ~w(shortcuts calendars date_sheet) do
    test "opening the #{menu} modal closes the preview behind it", %{
      conn: conn,
      integration: integration
    } do
      review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{review.id}")
      assert has_element?(lv, "#calendar-preview")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:toggle_menu", %{"menu" => unquote(menu)})

      refute has_element?(lv, "#calendar-preview")
    end
  end

  test "opening the import modal closes the preview behind it", %{
    conn: conn,
    integration: integration
  } do
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{review.id}")

    lv |> element("#calendar-canvas") |> render_hook("calendar:ics_open", %{})

    assert has_element?(lv, "#calendar-import")
    refute has_element?(lv, "#calendar-preview")
  end

  test "a click elsewhere closes the preview without taking focus", %{
    conn: conn,
    integration: integration
  } do
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{review.id}")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:close_preview", %{"refocus" => "false"})

    refute has_element?(lv, "#calendar-preview")
    refute_push_event(lv, "calendar:preview-closed", _payload)
  end

  test "only the click-away is told not to take focus", %{conn: conn, integration: integration} do
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{review.id}")

    html = lv |> element("#calendar-preview") |> render()

    assert [_all, click_away] = Regex.run(~r/phx-click-away="([^"]*)"/, html)
    assert click_away =~ "refocus"
    refute html =~ "phx-value-refocus"
  end

  describe "what the event means for bookings" do
    test "an account that counts every event as busy makes a free event block", %{
      conn: conn,
      user: user
    } do
      busy_account =
        insert(:calendar_integration,
          user: user,
          name: "Holidays",
          provider: "google",
          is_active: true,
          all_events_busy: true,
          calendar_list: [%{"id" => "hol", "name" => "Holidays", "selected" => true}]
        )

      holiday =
        event(busy_account, "hol", "Bank holiday", ~U[2026-10-15 09:00:00Z], 60,
          transparency: "transparent"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{holiday.id}")

      assert has_element?(lv, "#calendar-preview", "Guests can't book this time")
      refute has_element?(lv, "#calendar-preview", "Guests can book this time")
    end

    test "a declined event does not block", %{conn: conn, integration: integration} do
      declined =
        event(integration, "work", "Declined", ~U[2026-10-15 09:00:00Z], 60, status: "declined")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{declined.id}")

      assert has_element?(lv, "#calendar-preview", "Guests can book this time")
    end

    test "a calendar shown without blocking says so", %{conn: conn, user: user} do
      show_only =
        insert(:calendar_integration,
          user: user,
          name: "Holidays",
          provider: "google",
          is_active: true,
          calendar_list: [
            %{
              "id" => "hol",
              "name" => "Holidays",
              "selected" => true,
              "blocks_availability" => false
            }
          ]
        )

      holiday = event(show_only, "hol", "Bank holiday", ~U[2026-10-15 09:00:00Z])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{holiday.id}")

      assert has_element?(lv, "#calendar-preview", "This calendar doesn't block bookings")
    end
  end

  describe "the time line" do
    test "an all-day event says so", %{conn: conn, integration: integration} do
      day =
        event(integration, "work", "Offsite", ~U[2026-10-15 00:00:00Z], 60,
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-10-15],
          end_date: ~D[2026-10-16]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{day.id}")

      assert has_element?(lv, "#calendar-preview", "Thu 15 Oct, all day")
    end

    test "a multi-day all-day event shows its first and last day", %{
      conn: conn,
      integration: integration
    } do
      trip =
        event(integration, "work", "Trip", ~U[2026-10-15 00:00:00Z], 60,
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-10-15],
          end_date: ~D[2026-10-18]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{trip.id}")

      assert has_element?(lv, "#calendar-preview", "Thu 15 Oct – Sat 17 Oct")
    end

    test "a timed event across midnight names both days", %{conn: conn, integration: integration} do
      night = event(integration, "work", "Release", ~U[2026-10-15 21:00:00Z], 600)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{night.id}")

      assert has_element?(lv, "#calendar-preview", "Thu 15 Oct, 22:00 – Fri 16 Oct, 08:00")
    end

    test "the organiser's 12-hour clock applies", %{conn: conn} do
      %{conn: conn, integration: integration} = owner(conn, preferences: [time_format: "12h"])
      review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{review.id}")

      assert has_element?(lv, "#calendar-preview", ~r/10:00\s?AM.*11:00\s?AM/)
    end

    test "a start a few seconds away reads as a minute away, never as now", %{
      conn: conn,
      integration: integration
    } do
      soon = event(integration, "work", "Soon", DateTime.add(now(), 20, :second))

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{soon.id}")

      assert has_element?(lv, "#calendar-preview", "in 1 min")
      refute has_element?(lv, "#calendar-preview", "Happening now")
    end

    test "a start one hour 59 minutes away rounds to 2 h", %{conn: conn, integration: integration} do
      later = event(integration, "work", "Later", DateTime.add(now(), 119, :minute))

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open(lv, "event-#{later.id}")

      assert has_element?(lv, "#calendar-preview", "in 2 h")
    end
  end

  test "guests past the fifth collapse into a count", %{conn: conn, integration: integration} do
    attendees =
      for n <- 1..7, do: %{"email" => "guest#{n}@example.com", "display_name" => "Guest #{n}"}

    crowd =
      event(integration, "work", "All hands", ~U[2026-10-15 09:00:00Z], 60, attendees: attendees)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{crowd.id}")

    assert has_element?(lv, "#calendar-preview-guests li", "Guest 5")
    assert has_element?(lv, "#calendar-preview-guests", "2 more guests")
    refute has_element?(lv, "#calendar-preview", "Guest 6")
  end

  test "opening a second event while a preview is open shows the second", %{
    conn: conn,
    integration: integration
  } do
    one = event(integration, "work", "First", ~U[2026-10-14 09:00:00Z])
    two = event(integration, "work", "Second", ~U[2026-10-15 09:00:00Z])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{one.id}")
    open(lv, "event-#{two.id}")

    assert has_element?(lv, "#calendar-preview-title", "Second")
  end

  test "hiding the previewed event's calendar closes its preview", %{
    conn: conn,
    integration: integration
  } do
    dentist = event(integration, "family", "Dentist", ~U[2026-10-16 14:00:00Z], 30)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{dentist.id}")
    assert has_element?(lv, "#calendar-preview", "Dentist")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:toggle_calendar", %{
      "integration-id" => to_string(integration.id),
      "calendar-id" => "family"
    })

    refute has_element?(lv, "#calendar-preview")
  end
end
