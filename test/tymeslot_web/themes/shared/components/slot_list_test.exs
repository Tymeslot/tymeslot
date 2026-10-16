defmodule TymeslotWeb.Themes.Shared.Components.SlotListTest do
  @moduledoc """
  The slot panel every theme renders. Its screen-reader status line is the
  only way a keyboard or screen-reader user learns what picking a date did,
  and its hour toggle is the only thing tying an open minute drawer to the
  hour it belongs to, so both are pinned here once for every theme.

  Slot values use the "9:00 AM" shape the availability layer produces; the
  buttons render them through the visitor's clock ("09:00 AM" in English).
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TymeslotWeb.Themes.Shared.Components.SlotList

  @date "2026-09-10"
  @hour_slots ["9:00 AM", "9:05 AM", "10:00 AM"]

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  defp render_list(overrides) do
    assigns = Map.merge(%{target: nil, selected_date: @date}, Map.new(overrides))

    html = render_component(&SlotList.slot_list/1, assigns)
    Floki.parse_fragment!(html)
  end

  defp status(doc), do: doc |> Floki.find("[role=status]") |> Floki.text() |> String.trim()
  defp text(doc, selector), do: doc |> Floki.find(selector) |> Floki.text() |> String.trim()
  defp times(doc), do: Floki.attribute(doc, "[data-testid=time-slot]", "data-time")

  defp times_in(doc, scope),
    do: Floki.attribute(doc, "#{scope} [data-testid=time-slot]", "data-time")

  defp hour_attr(doc, hour, attr),
    do: Floki.attribute(doc, "[data-testid=slot-hour][phx-value-hour='#{hour}']", attr)

  defp hours(overrides \\ []) do
    [available_slots: @hour_slots, slot_interval_minutes: 5, duration_minutes: 30]
    |> Keyword.merge(overrides)
    |> render_list()
  end

  describe "screen-reader status" do
    test "asks for a date before one is picked" do
      doc = render_list(selected_date: nil, available_slots: ["9:00 AM"])

      assert status(doc) == "Please select a date to see available times"
    end

    test "announces loading, even with stale slots still assigned" do
      doc = render_list(loading_slots: true, available_slots: ["9:00 AM"])

      assert status(doc) == "Loading available times..."
    end

    test "announces loading ahead of an error from the previous fetch" do
      doc = render_list(loading_slots: true, calendar_error: "Calendar unavailable")

      assert status(doc) == "Loading available times..."
    end

    test "reads out the calendar error in place of the slots" do
      doc = render_list(calendar_error: "Calendar unavailable", available_slots: ["9:00 AM"])

      assert status(doc) == "Calendar unavailable"
    end

    test "announces the loaded times" do
      assert status(render_list(available_slots: ["9:00 AM"])) == "Available Times"
    end

    test "says the day is fully booked when nothing is free" do
      assert status(render_list(available_slots: [])) == "This date is fully booked"
    end
  end

  describe "visible states" do
    test "prompts for a date" do
      doc = render_list(selected_date: nil)

      assert text(doc, ".slot-list__prompt p") == "Please select a date to see available times"
      assert Floki.find(doc, "[data-slots-loaded]") == []
    end

    test "default loading, error and fully-booked markup" do
      assert text(render_list(loading_slots: true), ".slot-list__loading") ==
               "Loading available times..."

      assert text(render_list(calendar_error: "Calendar unavailable"), ".slot-list__error") ==
               "Calendar unavailable"

      assert render_list(available_slots: []) |> Floki.find(".slot-list__empty p") |> length() ==
               2
    end

    test "marks the loaded list with the date it shows, for the scroll hook" do
      doc = render_list(available_slots: ["9:00 AM"])

      assert Floki.attribute(doc, ".slot-list__groups", "data-slots-loaded") == [@date]
    end
  end

  describe "flat grouping" do
    setup do
      [
        doc:
          render_list(
            available_slots: ["9:00 AM", "9:30 AM", "2:00 PM"],
            selected_time: "9:30 AM",
            duration_minutes: 30
          )
      ]
    end

    test "groups by part of the day and drops the empty parts", %{doc: doc} do
      labels =
        doc |> Floki.find(".slot-list__period-label") |> Enum.map(&String.trim(Floki.text(&1)))

      assert labels == ["Morning", "Afternoon"]
    end

    test "renders every slot on the visitor's clock", %{doc: doc} do
      assert times(doc) == ["9:00 AM", "9:30 AM", "2:00 PM"]
      assert text(doc, "[data-testid=time-slot][data-time='2:00 PM']") == "02:00 PM"

      assert Floki.attribute(doc, "[data-testid=time-slot][data-time='9:00 AM']", "phx-click") ==
               ["select_time"]
    end

    test "marks only the selected slot", %{doc: doc} do
      assert Floki.attribute(doc, ".slot-list__slot--selected", "data-time") == ["9:30 AM"]
    end

    test "offers no hour toggles", %{doc: doc} do
      assert Floki.find(doc, "[data-testid=slot-hour]") == []
    end
  end

  describe "hour grouping" do
    test "opens the earliest hour and wires it to its drawer" do
      doc = hours()

      assert hour_attr(doc, 9, "aria-expanded") == ["true"]
      assert hour_attr(doc, 9, "aria-controls") == ["slot-hour-panel-9"]
      assert hour_attr(doc, 10, "aria-expanded") == ["false"]
      assert hour_attr(doc, 10, "aria-controls") == []
    end

    test "names each hour with its count, in the right plural" do
      doc = hours()

      assert hour_attr(doc, 9, "aria-label") == ["09:00 AM, 2 available times"]
      assert hour_attr(doc, 10, "aria-label") == ["10:00 AM, 1 available time"]

      assert Floki.attribute(doc, "[data-testid=slot-hour] span", "aria-hidden") ==
               ~w(true true true true)
    end

    test "shows only the open hour's minutes, in a labelled group" do
      doc = hours()

      assert Floki.attribute(doc, "#slot-hour-panel-9", "role") == ["group"]
      assert Floki.attribute(doc, "#slot-hour-panel-9", "aria-label") == ["09:00 AM"]
      assert times_in(doc, "#slot-hour-panel-9") == ["9:00 AM", "9:05 AM"]
      assert times(doc) == ["9:00 AM", "9:05 AM"]
    end

    test "opens the hour the visitor chose" do
      doc = hours(expanded_hour: 10)

      assert times_in(doc, "#slot-hour-panel-10") == ["10:00 AM"]
      assert Floki.find(doc, "#slot-hour-panel-9") == []
    end

    test "stays collapsed after a deliberate collapse" do
      doc = hours(expanded_hour: :none)

      assert Floki.find(doc, "[role=group]") == []

      assert Floki.attribute(doc, "[data-testid=slot-hour]", "aria-expanded") == [
               "false",
               "false"
             ]
    end

    test "marks the collapsed hour holding the selection, and the open hour as open" do
      doc = hours(selected_time: "10:00 AM")

      assert Floki.attribute(doc, ".slot-list__slot--selected", "phx-value-hour") == ["10"]
      assert Floki.attribute(doc, ".slot-list__slot--expanded", "phx-value-hour") == ["9"]
    end
  end

  describe "theme hooks" do
    test "heading and period labels take the theme's heading levels" do
      doc = render_list(available_slots: ["9:00 AM"], heading_tag: "h3", period_tag: "h4")

      assert Floki.attribute(doc, "h3.slot-list__heading", "tabindex") == ["-1"]
      assert text(doc, "h4.slot-list__period-label") == "Morning"
    end

    test "slots replace the default loading, error and empty markup" do
      render = fn assigns ->
        html =
          render_component(
            fn assigns ->
              ~H"""
              <SlotList.slot_list
                target={nil}
                selected_date="2026-09-10"
                loading_slots={@loading}
                calendar_error={@error}
                available_slots={[]}
              >
                <:loading>
                  <p id="own-loading">spinner</p>
                </:loading>
                <:error :let={message}>
                  <p id="own-error">{message}</p>
                </:error>
                <:empty>
                  <p id="own-empty">none</p>
                </:empty>
              </SlotList.slot_list>
              """
            end,
            assigns
          )

        Floki.parse_fragment!(html)
      end

      loading = render.(%{loading: true, error: nil})
      assert Floki.find(loading, "#own-loading") != []
      assert Floki.find(loading, ".slot-list__loading") == []

      assert text(render.(%{loading: false, error: "Calendar unavailable"}), "#own-error") ==
               "Calendar unavailable"

      assert Floki.find(render.(%{loading: false, error: nil}), "#own-empty") != []
    end
  end
end
