defmodule TymeslotWeb.Themes.Shared.Blocks.DayChipsTest do
  @moduledoc """
  The next free days as chips, from the month's availability map. Today is
  Wednesday 10 March 2027.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.Test.ClockHelpers
  alias TymeslotWeb.Themes.Shared.Blocks.DayChips

  @availability %{
    "2027-03-09" => true,
    "2027-03-10" => true,
    "2027-03-11" => true,
    "2027-03-12" => false,
    "2027-03-13" => true,
    "2027-03-20" => true
  }

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    ClockHelpers.freeze_clock(~U[2027-03-10 12:00:00Z])
    :ok
  end

  defp render_chips(overrides \\ []) do
    assigns =
      Map.merge(
        %{availability: @availability, user_timezone: "Etc/UTC", count: 3, target: nil},
        Map.new(overrides)
      )

    (&DayChips.day_chips/1)
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  defp chips(doc) do
    for chip <- Floki.find(doc, "[data-fact=date]") do
      {chip |> Floki.attribute("data-value") |> hd(),
       chip |> Floki.find(".day-chips__label") |> Floki.text() |> String.trim()}
    end
  end

  test "offers the first free days from today, labelled as a visitor says them" do
    assert chips(render_chips()) == [
             {"2027-03-10", "Today"},
             {"2027-03-11", "Tomorrow"},
             {"2027-03-13", "Sat 13"}
           ]
  end

  test "takes today from the visitor's timezone, not the UTC date" do
    # 23:30 UTC on 10 March is already 11 March in Tokyo.
    ClockHelpers.freeze_clock(~U[2027-03-10 23:30:00Z])

    assert chips(render_chips(user_timezone: "Asia/Tokyo")) == [
             {"2027-03-11", "Today"},
             {"2027-03-13", "Sat 13"},
             {"2027-03-20", "Sat 20"}
           ]

    assert Floki.find(render_chips(user_timezone: "Asia/Tokyo"), ".day-chips__chip--today") != []
  end

  test "sends select_date from each chip" do
    doc = render_chips()

    assert Floki.attribute(doc, "[data-value='2027-03-13']", "phx-click") == ["select_date"]
    assert Floki.attribute(doc, "[data-value='2027-03-13']", "phx-value-date") == ["2027-03-13"]
    assert Floki.attribute(doc, "[role=group]", "aria-label") == ["Select a Date"]
  end

  test "names each chip by its visible label plus the full date, with no aria-label" do
    doc = render_chips()
    [chip] = Floki.find(doc, "[data-value='2027-03-13']")

    # As NextSlots: the name is the content, not an aria-label that replaces it.
    assert Floki.attribute(chip, "aria-label") == []
    assert [label] = Floki.find(chip, ".day-chips__label")
    assert Floki.attribute(label, "aria-hidden") == ["true"]
    assert Floki.text(label) == "Sat 13"
    assert chip |> Floki.find(".sr-only") |> Floki.text() == "Saturday, March 13, 2027"
  end

  test "marks the chosen day" do
    doc = render_chips(selected_date: "2027-03-11")

    assert Floki.attribute(doc, "[data-value='2027-03-11']", "aria-pressed") == ["true"]
    assert Floki.attribute(doc, "[data-value='2027-03-10']", "aria-pressed") == ["false"]
  end

  test "says it is loading while the month's availability is being fetched" do
    doc = render_chips(availability: :loading, availability_status: :loading)

    assert chips(doc) == []
    assert doc |> Floki.find(".day-chips__loading") |> Floki.text() =~ "Loading available times"
    assert Floki.find(doc, ".day-chips__empty") == []
  end

  test "says it is loading before a fetch has started" do
    doc = render_chips(availability: nil)

    assert chips(doc) == []
    assert doc |> Floki.find(".day-chips__loading") |> Floki.text() =~ "Loading available times"
  end

  test "says so when the fetch failed, instead of loading for ever" do
    doc = render_chips(availability: nil, availability_status: :error)

    assert chips(doc) == []
    assert doc |> Floki.find(".day-chips__error") |> Floki.text() =~ "Calendar is loading slowly"
    assert Floki.find(doc, ".day-chips__loading") == []
    assert Floki.find(doc, ".day-chips__empty") == []
  end

  test "says when no day is free" do
    doc = render_chips(availability: %{"2027-03-11" => false})

    assert chips(doc) == []
    assert doc |> Floki.find(".day-chips__empty") |> Floki.text() =~ "No times available"
  end
end
