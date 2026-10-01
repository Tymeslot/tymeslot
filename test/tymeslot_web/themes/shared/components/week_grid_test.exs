defmodule TymeslotWeb.Themes.Shared.Components.WeekGridTest do
  @moduledoc """
  The week of times a week view renders. Pinned here once for every theme
  that uses it: the seven days from the week's Monday with their own times,
  the one selected time, the states before, during and after a fetch, the
  navigation bounds, and that it asks for its week only while it has none.

  Slot values use the "9:00 AM" shape the availability layer produces; the
  buttons render them through the visitor's clock ("09:00 AM" in English).
  The clock is frozen on the Wednesday of the week shown.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]

  alias Tymeslot.Test.ClockHelpers
  alias TymeslotWeb.Themes.Shared.Components.WeekGrid

  @week_start ~D[2027-03-08]

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    ClockHelpers.freeze_clock(~U[2027-03-10 12:00:00Z])
    :ok
  end

  defp render_grid(overrides) do
    assigns =
      Map.merge(
        %{
          week_start: @week_start,
          week_slots: %{},
          user_timezone: "Etc/UTC",
          booking_window_days: 30,
          target: nil
        },
        Map.new(overrides)
      )

    (&WeekGrid.week_grid/1)
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  defp attr(node, name), do: node |> Floki.attribute(name) |> List.first()
  defp text(doc, selector), do: doc |> Floki.find(selector) |> Floki.text() |> String.trim()

  defp slots(doc) do
    doc
    |> Floki.find("[data-testid=week-slot]")
    |> Enum.map(&{attr(&1, "data-date"), attr(&1, "data-time")})
  end

  describe "the week" do
    test "has the seven days from the week's Monday" do
      doc = render_grid([])

      assert Floki.attribute(doc, ".week-grid__day", "data-date") ==
               Enum.map(0..6, &(@week_start |> Date.add(&1) |> Date.to_iso8601()))

      assert attr(Floki.find(doc, "[data-testid=week-grid]"), "data-week-start") ==
               "2027-03-08"
    end

    test "lists each day's own times under it, in order" do
      doc =
        render_grid(
          week_slots: %{
            "2027-03-08" => ["9:00 AM", "9:30 AM"],
            "2027-03-09" => ["2:00 PM"]
          }
        )

      assert slots(doc) == [
               {"2027-03-08", "9:00 AM"},
               {"2027-03-08", "9:30 AM"},
               {"2027-03-09", "2:00 PM"}
             ]

      assert doc |> Floki.find("[data-testid=week-slot]") |> hd() |> Floki.text() |> String.trim() ==
               "09:00 AM"
    end

    test "reads the demo provider's slot maps as it reads plain times" do
      doc = render_grid(week_slots: %{"2027-03-08" => [%{time: "9:00 AM", available: true}]})

      assert slots(doc) == [{"2027-03-08", "9:00 AM"}]
    end

    test "marks the chosen time on its own day only" do
      doc =
        render_grid(
          week_slots: %{"2027-03-08" => ["9:00 AM"], "2027-03-09" => ["9:00 AM"]},
          selected_date: "2027-03-09",
          selected_time: "9:00 AM"
        )

      assert [selected] = Floki.find(doc, ".week-grid__slot--selected")
      assert attr(selected, "data-date") == "2027-03-09"
      assert attr(selected, "aria-pressed") == "true"

      assert doc
             |> Floki.find("[data-testid=week-slot][data-date='2027-03-08']")
             |> attr("aria-pressed") == "false"
    end

    test "says so on a day with nothing free" do
      doc = render_grid(week_slots: %{"2027-03-08" => ["9:00 AM"]})

      assert text(doc, ".week-grid__day[data-date='2027-03-10'] .week-grid__empty") ==
               "No times available"

      assert Floki.find(doc, ".week-grid__day[data-date='2027-03-08'] .week-grid__empty") == []
    end

    test "marks the visitor's today" do
      doc = render_grid(today: ~D[2027-03-10])

      assert Floki.attribute(doc, ".week-grid__day--today", "data-date") == ["2027-03-10"]
    end

    test "sends the day and the time of the time clicked" do
      doc = render_grid(week_slots: %{"2027-03-11" => ["4:00 PM"]}, target: "#schedule")
      [button] = Floki.find(doc, "[data-testid=week-slot]")

      assert attr(button, "phx-click") == "select_slot"
      assert attr(button, "phx-value-date") == "2027-03-11"
      assert attr(button, "phx-value-time") == "4:00 PM"
      assert attr(button, "phx-target") == "#schedule"
    end

    test "speaks German to a German visitor" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      doc = render_grid([])

      assert text(doc, ".week-grid__day[data-date='2027-03-08'] .week-grid__empty") ==
               "Keine Zeiten verfügbar"

      assert attr(Floki.find(doc, "[data-testid=week-grid-prev]"), "aria-label") ==
               "Vorherige Woche"
    end
  end

  describe "fetching the week" do
    test "asks for its week, on appearing and on every join, while it has none" do
      doc = render_grid(week_slots: nil)
      [grid] = Floki.find(doc, "[data-testid=week-grid]")

      assert attr(grid, "phx-mounted") =~ "load_week"
      assert attr(grid, "phx-connected") =~ "load_week"
      assert text(doc, ".week-grid__loading") == "Loading available times..."
      assert Floki.find(doc, ".week-grid__day") == []
    end

    test "stops asking once a week has been asked for" do
      [grid] = Floki.find(render_grid(week_slots: %{}), "[data-testid=week-grid]")

      assert attr(grid, "phx-mounted") == nil
      assert attr(grid, "phx-connected") == nil
    end

    test "shows the loading state for a week still on its way" do
      doc = render_grid(week_slots: %{}, loading: true)

      assert text(doc, ".week-grid__loading") == "Loading available times..."
      assert text(doc, "[role=status]") == "Loading available times..."
      assert Floki.find(doc, ".week-grid__day") == []
    end

    test "keeps a week on screen while the same week is fetched again" do
      doc = render_grid(week_slots: %{"2027-03-08" => ["9:00 AM"]}, loading: true)

      assert slots(doc) == [{"2027-03-08", "9:00 AM"}]
      assert Floki.find(doc, ".week-grid.week-grid--loading") != []

      buttons = Floki.find(doc, "[data-testid=week-slot]")
      assert buttons != []
      assert Enum.reject(buttons, &(Floki.attribute(&1, "disabled") != [])) == []
    end

    test "leaves the times clickable once the fetch is done" do
      doc = render_grid(week_slots: %{"2027-03-08" => ["9:00 AM"]}, loading: false)

      [button] = Floki.find(doc, "[data-testid=week-slot]")
      assert Floki.attribute(button, "disabled") == []
    end

    test "shows a failed fetch in place of the days" do
      doc =
        render_grid(
          week_slots: %{"2027-03-08" => ["9:00 AM"]},
          error: "No time slots could be loaded. Please try again."
        )

      assert text(doc, ".week-grid__error") ==
               "No time slots could be loaded. Please try again."

      assert text(doc, "[role=status]") == "No time slots could be loaded. Please try again."
      assert slots(doc) == []
    end

    test "announces the loaded week" do
      assert text(render_grid([]), "[role=status]") == "Available Times"
    end
  end

  describe "week navigation" do
    test "cannot go back from the week holding today, and can go on" do
      doc = render_grid([])

      assert [_button] = Floki.find(doc, "[data-testid=week-grid-prev][disabled]")
      assert attr(Floki.find(doc, "[data-testid=week-grid-next]"), "disabled") == nil
      assert attr(Floki.find(doc, "[data-testid=week-grid-next]"), "phx-click") == "next_week"
      assert attr(Floki.find(doc, "[data-testid=week-grid-prev]"), "phx-click") == "prev_week"
    end

    test "can go back from a later week" do
      doc = render_grid(week_start: ~D[2027-03-15])

      assert attr(Floki.find(doc, "[data-testid=week-grid-prev]"), "disabled") == nil
    end

    test "cannot go on past the booking window" do
      doc = render_grid(booking_window_days: 3)

      assert [_button] = Floki.find(doc, "[data-testid=week-grid-next][disabled]")
    end
  end

  describe "the first available week" do
    test "offers a way back to it from any other week" do
      doc =
        render_grid(week_start: ~D[2027-03-22], landing_week: @week_start, target: "#schedule")

      [jump] = Floki.find(doc, "[data-testid=week-grid-first-available]")

      assert attr(jump, "phx-click") == "first_available_week"
      assert attr(jump, "phx-target") == "#schedule"
      assert jump |> Floki.text() |> String.trim() == "Jump to first available"
    end

    test "offers none on that week, or when the page landed on no day" do
      assert Floki.find(
               render_grid(landing_week: @week_start),
               "[data-testid=week-grid-first-available]"
             ) == []

      assert Floki.find(
               render_grid(week_start: ~D[2027-03-22]),
               "[data-testid=week-grid-first-available]"
             ) == []
    end

    test "speaks German to a German visitor" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      doc = render_grid(week_start: ~D[2027-03-22], landing_week: @week_start)

      assert text(doc, "[data-testid=week-grid-first-available]") == "Zum ersten freien Termin"
    end
  end

  defp render_with_slot(overrides) do
    assigns =
      Map.merge(
        %{
          week_start: @week_start,
          week_slots: %{"2027-03-08" => ["9:00 AM"]},
          loading: false,
          error: nil
        },
        Map.new(overrides)
      )

    ~H"""
    <WeekGrid.week_grid
      week_start={@week_start}
      week_slots={@week_slots}
      loading={@loading}
      error={@error}
      user_timezone="Etc/UTC"
      booking_window_days={30}
      target={nil}
    >
      <:before_days>
        <p data-testid="theme-strip">Strip</p>
      </:before_days>
    </WeekGrid.week_grid>
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
  end

  # The grid's own children, in document order, named by their class or
  # test id: where the slot lands relative to the navigation and the days.
  defp children(doc) do
    [{"div", _attrs, kids}] = Floki.find(doc, "[data-testid=week-grid]")

    for {_tag, _attrs, _kids} = kid <- kids do
      attr(kid, "data-testid") || kid |> attr("class") |> String.split() |> hd()
    end
  end

  describe "what a theme puts before the days" do
    test "sits between the week navigation and the days" do
      assert children(render_with_slot([])) == [
               "week-grid__nav",
               "theme-strip",
               "sr-only",
               "week-grid__days"
             ]
    end

    test "stays on screen while the week loads and when it fails" do
      assert "theme-strip" in children(render_with_slot(week_slots: nil))

      assert "theme-strip" in children(
               render_with_slot(error: "No time slots could be loaded. Please try again.")
             )
    end

    test "adds nothing when a theme passes none" do
      assert children(render_grid([])) == ["week-grid__nav", "sr-only", "week-grid__days"]
    end
  end
end
