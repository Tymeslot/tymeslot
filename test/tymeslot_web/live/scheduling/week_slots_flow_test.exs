defmodule TymeslotWeb.Live.Scheduling.WeekSlotsFlowTest do
  @moduledoc """
  A week of slots through a real booking page: the fixture theme
  (`test/support/fixture_theme/`), whose schedule step renders the shared
  `WeekGrid`. In a browser the grid sends `load_week` from its `phx-mounted`
  binding; LiveViewTest runs no bindings, so these tests send it to the step
  as the binding would. Each fetch is a `start_async/3` task, which
  `render_async/1` waits for.

  The page opens on a linked day nine days out (`?date=`), so the week shown
  lies wholly after today and inside the host's 30-day window, and every
  time on it is the host's 9:00 to 17:00 whatever the hour the suite runs at.
  What the grid shows is compared with `Offer.slots_for_range/4` for that
  week, which `OfferRangeTest` holds equal to the per-day offer.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Availability.Offer
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @fixture_theme_id "99"
  @timezone "Etc/UTC"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()
    AvailabilityCache.clear_all()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  describe "loading the week" do
    test "the grid waits for its week, then shows the host's times on it", %{conn: conn} do
      %{view: view} = page = open_schedule(conn, "week-load")

      assert has_element?(view, "[data-testid='week-grid'] .week-grid__loading")
      refute has_element?(view, "[data-testid='week-slot']")

      load_week(view)

      assert grid_week(view) == Date.beginning_of_week(linked_day(), :monday)
      assert shown_slots(view) != []
      assert shown_slots(view) == offered(page, grid_week(view), @timezone)
    end
  end

  describe "week navigation" do
    test "next and previous week each show the week they move to", %{conn: conn} do
      %{view: view} = page = open_schedule(conn, "week-nav")
      load_week(view)
      week = grid_week(view)

      view |> element("[data-testid='week-grid-next']") |> render_click()
      render_async(view)

      assert grid_week(view) == Date.add(week, 7)
      assert shown_slots(view) == offered(page, Date.add(week, 7), @timezone)

      view |> element("[data-testid='week-grid-prev']") |> render_click()
      render_async(view)

      assert grid_week(view) == week
      assert shown_slots(view) == offered(page, week, @timezone)
    end

    test "moving on twice before the first week arrives shows the second", %{conn: conn} do
      %{view: view} = page = open_schedule(conn, "week-twice")
      load_week(view)
      week = grid_week(view)

      # The first fetch waits inside the calendar read until the second click
      # cancels it: a task killed in the middle of a database query would take
      # the test's sandbox connection down with it.
      test_pid = self()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        send(test_pid, {:calendar_read, self()})

        receive do
          :release -> {:ok, []}
        end
      end)

      view |> element("[data-testid='week-grid-next']") |> render_click()
      assert_receive {:calendar_read, first_fetch}
      ref = Process.monitor(first_fetch)

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
      view |> element("[data-testid='week-grid-next']") |> render_click()
      render_async(view)

      assert_receive {:DOWN, ^ref, :process, ^first_fetch, _reason}
      assert grid_week(view) == Date.add(week, 14)
      assert shown_slots(view) == offered(page, Date.add(week, 14), @timezone)
    end
  end

  describe "fetching the week again" do
    test "a timezone change shows the week's times in the new zone", %{conn: conn} do
      %{view: view} = page = open_schedule(conn, "week-zone")
      load_week(view)
      refute Enum.any?(shown_slots(view), &match?({_date, "6:00 PM"}, &1))

      view
      |> with_target("[data-testid='fixture-schedule']")
      |> render_click("change_timezone", %{"timezone" => "Asia/Tokyo"})

      render_async(view)

      assert shown_slots(view) == offered(page, grid_week(view), "Asia/Tokyo")
      assert Enum.any?(shown_slots(view), &match?({_date, "6:00 PM"}, &1))
    end

    test "a time still on screen while the week is fetched again cannot be picked",
         %{conn: conn} do
      %{view: view} = open_schedule(conn, "week-stale")
      load_week(view)
      [{day, time} | _rest] = shown_slots(view)

      view
      |> with_target("[data-testid='fixture-schedule']")
      |> render_click("change_timezone", %{"timezone" => "Asia/Tokyo"})

      slot = "[data-testid='week-slot'][data-date='#{day}'][data-time='#{time}']"
      assert has_element?(view, slot <> "[disabled]")

      view
      |> with_target("[data-testid='fixture-schedule']")
      |> render_click("select_slot", %{"date" => day, "time" => time})

      refute has_element?(view, "[data-testid='week-slot'][aria-pressed='true']")
      assert has_element?(view, "[data-testid='next-step'][disabled]")

      render_async(view)
      assert has_element?(view, "[data-testid='week-slot']:not([disabled])")
    end

    test "a calendar sync takes off the week a time the host's calendar now holds",
         %{conn: conn} do
      %{view: view, user: user} = open_schedule(conn, "week-sync")
      load_week(view)
      day = grid_week(view) |> Date.add(1) |> Date.to_iso8601()
      assert {day, "9:00 AM"} in shown_slots(view)

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:ok, [busy(day, ~T[09:00:00], ~T[10:00:00])]}
      end)

      send(view.pid, {:calendar_events_updated, user.id, []})
      render_async(view)

      refute {day, "9:00 AM"} in shown_slots(view)
      assert {day, "10:00 AM"} in shown_slots(view)
    end
  end

  describe "picking a time" do
    test "one click picks the day and the time, and Next takes them to the booking step",
         %{conn: conn} do
      %{view: view} = open_schedule(conn, "week-pick")
      load_week(view)
      day = grid_week(view) |> Date.add(2) |> Date.to_iso8601()
      slot = "[data-testid='week-slot'][data-date='#{day}'][data-time='10:00 AM']"

      assert has_element?(view, "[data-testid='next-step'][disabled]")

      view |> element(slot) |> render_click()

      assert has_element?(view, slot <> "[aria-pressed='true']")
      refute has_element?(view, "[data-testid='next-step'][disabled]")

      view |> element("[data-testid='next-step']") |> render_click()

      assert has_element?(view, "[data-testid='fixture-booking-slot']", "#{day} 10:00 AM")
    end

    test "a time the week does not offer picks nothing", %{conn: conn} do
      %{view: view} = open_schedule(conn, "week-forged")
      load_week(view)
      day = grid_week(view) |> Date.add(2) |> Date.to_iso8601()

      view
      |> with_target("[data-testid='fixture-schedule']")
      |> render_click("select_slot", %{"date" => day, "time" => "3:15 AM"})

      refute has_element?(view, "[data-testid='week-slot'][aria-pressed='true']")
      assert has_element?(view, "[data-testid='next-step'][disabled]")
    end
  end

  describe "jumping to the first available week" do
    test "brings a booker who moved on back to the week the page landed them on",
         %{conn: conn} do
      %{view: view} = page = open_landed_schedule(conn, "week-jump")
      load_week(view)
      landed = grid_week(view)
      refute has_element?(view, "[data-testid='week-grid-first-available']")

      for _week <- 1..2 do
        view |> element("[data-testid='week-grid-next']") |> render_click()
        render_async(view)
      end

      assert grid_week(view) == Date.add(landed, 14)

      view |> element("[data-testid='week-grid-first-available']") |> render_click()
      render_async(view)

      assert grid_week(view) == landed
      assert shown_slots(view) == offered(page, landed, @timezone)
      refute has_element?(view, "[data-testid='week-grid-first-available']")
    end
  end

  # Nine days out: the Monday-started week holding it starts three to nine
  # days from today and ends inside the 30-day booking window.
  defp linked_day, do: Date.add(Date.utc_today(), 9)

  defp open_schedule(conn, username) do
    %{user: user, profile: profile} =
      seed_booking_account(@fixture_theme_id, username, @timezone)

    query = URI.encode_query(%{"timezone" => @timezone, "date" => Date.to_iso8601(linked_day())})
    {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")

    view |> element("[data-testid='duration-option']") |> render_click()
    view |> element("[data-testid='next-step']") |> render_click()

    %{view: view, user: user, profile: profile}
  end

  # No linked day: the page lands the booker on their first free day itself.
  defp open_landed_schedule(conn, username) do
    %{user: user, profile: profile} =
      seed_booking_account(@fixture_theme_id, username, @timezone)

    {:ok, view, _html} =
      live(conn, "/#{profile.username}?#{URI.encode_query(%{"timezone" => @timezone})}")

    view |> element("[data-testid='duration-option']") |> render_click()
    view |> element("[data-testid='next-step']") |> render_click()

    %{view: view, user: user, profile: profile}
  end

  # What the grid's phx-mounted binding sends in a browser.
  defp load_week(view) do
    view |> with_target("[data-testid='fixture-schedule']") |> render_click("load_week", %{})
    render_async(view)
  end

  defp grid_week(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("[data-testid='week-grid']", "data-week-start")
    |> List.first()
    |> Date.from_iso8601!()
  end

  defp shown_slots(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("[data-testid='week-slot']")
    |> Enum.map(&{attr(&1, "data-date"), attr(&1, "data-time")})
  end

  defp attr(node, name), do: node |> Floki.attribute(name) |> List.first()

  defp offered(%{user: user, profile: profile}, week_start, timezone) do
    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)
    request = %{profile: profile, user_timezone: timezone, meeting_type: meeting_type}

    {:ok, week} =
      Offer.slots_for_range(
        request,
        week_start,
        Date.add(week_start, 6),
        meeting_type.duration_minutes
      )

    for {date, slots} <- Enum.sort(week), slot <- slots, do: {date, slot}
  end

  defp busy(iso, from, to) do
    date = Date.from_iso8601!(iso)

    %{
      uid: "busy-#{iso}",
      start_time: DateTime.new!(date, from, @timezone),
      end_time: DateTime.new!(date, to, @timezone),
      status: "confirmed",
      transparency: "opaque",
      summary: "Busy"
    }
  end
end
