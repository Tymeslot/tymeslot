defmodule TymeslotWeb.Themes.Quill.ScheduleSlotsTest do
  @moduledoc """
  Covers how Quill presents a day's slots.

  A meeting type offering starts on a grid finer than its own duration turns a
  working day into a hundred-odd buttons, so Quill nests them one level deeper:
  the booker sees an hour per button and opens one hour at a time. Every other
  meeting type keeps the flat grid it has always had, which is the case the
  last test pins.

  Expected times are read off the rendered attributes rather than written into
  the test, so an assertion cannot quietly stop matching what is offered.
  """

  # Each theme's assertions are repeated rather than shared. The fixture and the
  # generic page reads live in Tymeslot.SlotPickerTestHelpers, but the assertions
  # stay inline: they are the subject of these tests, and folding them into a
  # helper taking per-theme selectors would trade the thing worth reading for
  # indirection. Credo counts the two copies as duplication; that is the trade.
  # credo:disable-for-this-file Credo.Check.Design.DuplicatedCode

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SlotPickerTestHelpers

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    booking_page("quillslots", "1")
  end

  describe "a grid finer than the meeting" do
    setup %{user: user} do
      # 5-minute starts on a 30-minute meeting: the only shape that produces
      # the two-tier picker.
      insert(:meeting_type,
        user: user,
        name: "Rapid Fire",
        duration_minutes: 30,
        slot_interval_minutes: 5,
        is_active: true
      )

      :ok
    end

    @tag :capture_log
    test "offers hours rather than every minute of the day",
         %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      hours = rendered_hours(view)
      assert length(hours) > 1

      open = List.first(hours)
      times = rendered_times(view)
      assert times != []

      assert Enum.all?(times, &(TimeSlots.parse_time_slot(&1).hour == open)),
             "expected only the open hour's minutes to render, got: #{inspect(times)}"

      # The same minute offset in a closed hour is certainly on offer, and must
      # not be on the page. Deriving it from a rendered time keeps the format
      # and the minute honest.
      closed = List.last(hours)
      refute has_element?(view, slot_selector(minute_of(times, closed)))
    end

    @tag :capture_log
    test "opens the earliest hour so real times are visible without a click",
         %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      earliest = List.first(rendered_hours(view))

      assert has_element?(
               view,
               "[data-testid='slot-hour'][phx-value-hour='#{earliest}'][aria-expanded='true']"
             )

      times = rendered_times(view)
      assert times != []
      assert Enum.all?(times, &(TimeSlots.parse_time_slot(&1).hour == earliest))
      assert has_element?(view, slot_selector(List.first(times)))
    end

    @tag :capture_log
    test "opening a later hour reveals its minutes", %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      hours = rendered_hours(view)
      later = List.last(hours)
      refute later == List.first(hours)

      expected = minute_of(rendered_times(view), later)
      refute has_element?(view, slot_selector(expected))

      view |> element("[data-testid='slot-hour'][phx-value-hour='#{later}']") |> render_click()

      assert has_element?(view, slot_selector(expected))
      assert Enum.all?(rendered_times(view), &(TimeSlots.parse_time_slot(&1).hour == later))
    end

    @tag :capture_log
    test "keeps the selection visible on its hour once that hour collapses",
         %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      hours = rendered_hours(view)
      open = List.first(hours)
      later = List.last(hours)
      refute open == later

      chosen = view |> rendered_times() |> List.first()
      view |> element(slot_selector(chosen)) |> render_click()

      # Opening a different hour collapses the one holding the selection, so
      # the chosen minute button leaves the DOM entirely. Without a marker on
      # the hour itself the booker would have a selection with nothing on
      # screen to show for it, while "next" stayed enabled.
      view |> element("[data-testid='slot-hour'][phx-value-hour='#{later}']") |> render_click()

      refute has_element?(view, slot_selector(chosen))

      assert has_element?(
               view,
               "button.time-slot-button--hour.time-slot-button--selected[phx-value-hour='#{open}']"
             )
    end

    @tag :capture_log
    test "points aria-controls only at a panel that is actually in the DOM",
         %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      hours = rendered_hours(view)
      open = List.first(hours)
      collapsed = List.last(hours)
      refute open == collapsed

      doc = document(view)
      open_button = "[data-testid='slot-hour'][phx-value-hour='#{open}']"
      collapsed_button = "[data-testid='slot-hour'][phx-value-hour='#{collapsed}']"

      assert Floki.attribute(doc, open_button, "aria-controls") == [
               "slot-hour-panel-#{open}"
             ]

      assert Floki.find(doc, "#slot-hour-panel-#{open}") != []

      # A collapsed hour has no panel rendered, so it must not name one: an
      # aria-controls pointing at a missing id is a dangling reference.
      assert Floki.attribute(doc, collapsed_button, "aria-controls") == []
      assert Floki.find(doc, "#slot-hour-panel-#{collapsed}") == []

      # The control names itself rather than announcing a bare, unitless count.
      # Asserted structurally so a locale change cannot break it.
      [label] = Floki.attribute(doc, open_button, "aria-label")
      assert String.trim(label) != ""
      refute String.trim(label) =~ ~r/^\d+$/
    end

    @tag :capture_log
    test "selecting a minute records the choice", %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      open = List.first(rendered_hours(view))
      chosen = view |> rendered_times() |> List.first()

      view |> element(slot_selector(chosen)) |> render_click()

      # Scoped to the open hour's panel, so the assertion only holds while the
      # minutes really are nested under their hour.
      assert has_element?(
               view,
               "#slot-hour-panel-#{open} " <>
                 "button.time-slot-button--selected[phx-value-time='#{chosen}']"
             )
    end
  end

  describe "a meeting type with no interval of its own" do
    setup %{user: user} do
      insert(:meeting_type,
        user: user,
        name: "Standard",
        duration_minutes: 30,
        slot_interval_minutes: nil,
        is_active: true
      )

      :ok
    end

    @tag :capture_log
    test "keeps the flat grid", %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      refute has_element?(view, "[data-testid='slot-hour']")

      times = rendered_times(view)
      assert times != []

      assert times |> Enum.map(&TimeSlots.parse_time_slot(&1).hour) |> Enum.uniq() |> length() > 1,
             "expected the flat grid to show every hour's slots at once"
    end
  end

  defp reach_loaded_slots(conn, profile) do
    timezone = profile.timezone
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{timezone}")

    view |> element("button[data-testid='duration-option']") |> render_click()
    view |> element("button[data-testid='next-step']") |> render_click()

    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target = Date.add(today, 1)

    if target.month != today.month do
      view |> element("button[phx-click='next_month']") |> render_click()
    end

    date = Date.to_string(target)

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date}']") |> render_click()
    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    view
  end

  # Hour buttons carry no `phx-value-time`, so this is exactly the minute slots.
  defp rendered_times(view) do
    view |> document() |> Floki.attribute("button.time-slot-button", "phx-value-time")
  end

  defp slot_selector(time), do: "button.time-slot-button[phx-value-time='#{time}']"
end
