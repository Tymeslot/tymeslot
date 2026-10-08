defmodule TymeslotWeb.Themes.Shared.Blocks.NextSlotsTest do
  @moduledoc """
  The soonest free times across days, for a journey that starts from time.
  Today is Wednesday 10 March 2027, in the week from Monday 8 March; slot
  values have the "9:00 AM" shape the availability layer produces.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.Test.ClockHelpers
  alias TymeslotWeb.Themes.Shared.Blocks.NextSlots

  @week %{
    "2027-03-08" => ["9:00 AM"],
    "2027-03-10" => ["9:00 AM", "9:30 AM"],
    "2027-03-11" => [],
    "2027-03-12" => ["2:00 PM"],
    "2027-03-13" => ["10:00 AM"],
    "2027-03-14" => ["11:00 AM"]
  }

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    ClockHelpers.freeze_clock(~U[2027-03-10 12:00:00Z])
    :ok
  end

  defp render_slots(overrides \\ []) do
    assigns =
      Map.merge(
        %{id: "now-slots", week_slots: @week, user_timezone: "Etc/UTC", days: 3, target: nil},
        Map.new(overrides)
      )

    (&NextSlots.next_slots/1)
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  defp slots(doc, selector) do
    for slot <- Floki.find(doc, selector) do
      {slot |> Floki.attribute("data-date") |> hd(), slot |> Floki.attribute("data-time") |> hd()}
    end
  end

  test "offers the soonest days' times from today as slot facts" do
    doc = render_slots()

    assert slots(doc, ".next-slots__day:not([hidden]) [data-fact=slot]") == [
             {"2027-03-10", "9:00 AM"},
             {"2027-03-10", "9:30 AM"},
             {"2027-03-12", "2:00 PM"},
             {"2027-03-13", "10:00 AM"}
           ]

    assert Floki.attribute(doc, "[data-date='2027-03-12'][data-fact=slot]", "phx-click") ==
             ["select_slot"]
  end

  test "takes today from the visitor's timezone, not the UTC date" do
    # 23:30 UTC on 10 March is already 11 March in Tokyo, so the 10th is past.
    ClockHelpers.freeze_clock(~U[2027-03-10 23:30:00Z])
    doc = render_slots(user_timezone: "Asia/Tokyo", days: 5)

    assert Floki.find(doc, "[data-date='2027-03-10']") == []

    assert doc
           |> Floki.find(".next-slots__day-label")
           |> Enum.map(&(&1 |> Floki.text() |> String.trim())) ==
             ["Tomorrow", "Sat 13", "Sun 14"]

    ClockHelpers.freeze_clock(~U[2027-03-11 23:30:00Z])
    doc = render_slots(user_timezone: "Asia/Tokyo", days: 5)

    assert doc |> Floki.find(".next-slots__day-label") |> hd() |> Floki.text() == "Today"
  end

  test "heads each day as a visitor says it" do
    headings =
      render_slots()
      |> Floki.find(".next-slots__day:not([hidden]) .next-slots__day-label")
      |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

    assert headings == ["Today", "Fri 12", "Sat 13"]
  end

  test "keeps the further days in the page behind More times" do
    doc = render_slots()

    assert slots(doc, ".next-slots__day--extra[hidden] [data-fact=slot]") ==
             [{"2027-03-14", "11:00 AM"}]

    assert [more] = Floki.attribute(doc, "[data-testid=next-slots-more]", "phx-click")
    assert more =~ "remove_attr"
    assert more =~ "#now-slots .next-slots__day--extra"
  end

  test "moves the focus to the first revealed day's heading only" do
    doc = render_slots(days: 1)

    assert [more] = Floki.attribute(doc, "[data-testid=next-slots-more]", "phx-click")
    assert [_remove, _hide, ["focus", %{"to" => target}]] = Jason.decode!(more)

    assert [heading] = Floki.find(doc, target)
    assert Floki.attribute(heading, "class") == ["next-slots__day-heading"]

    assert heading |> Floki.text() |> String.trim() =~ "Fri 12"
    assert length(Floki.find(doc, ".next-slots__day--extra .next-slots__day-heading")) == 3
  end

  test "tells assistive technology what More times controls" do
    doc = render_slots(days: 1)

    assert Floki.attribute(doc, "[data-testid=next-slots-more]", "aria-expanded") == ["false"]
    assert [controls] = Floki.attribute(doc, "[data-testid=next-slots-more]", "aria-controls")

    ids = String.split(controls, " ")

    extra_ids =
      doc |> Floki.find(".next-slots__day--extra") |> Enum.flat_map(&Floki.attribute(&1, "id"))

    assert ids != []
    assert Enum.sort(ids) == Enum.sort(extra_ids)
  end

  test "has no More control when the soonest days are all there is" do
    assert Floki.find(render_slots(days: 5), "[data-testid=next-slots-more]") == []
  end

  test "marks the chosen time" do
    doc = render_slots(selected_date: "2027-03-12", selected_time: "2:00 PM")

    assert Floki.attribute(doc, "[data-date='2027-03-12'][data-time='2:00 PM']", "aria-pressed") ==
             ["true"]
  end

  test "asks for its week while it has none" do
    doc = render_slots(week_slots: nil)

    assert [mounted] = Floki.attribute(doc, "[data-testid=next-slots]", "phx-mounted")
    assert mounted =~ "load_week"
    assert doc |> Floki.find(".next-slots__loading") |> Floki.text() =~ "Loading available times"
  end

  test "offers the next week when nothing is free from today on" do
    doc = render_slots(week_slots: %{"2027-03-08" => ["9:00 AM"], "2027-03-12" => []})

    assert slots(doc, "[data-fact=slot]") == []

    assert Floki.attribute(doc, "[data-testid=next-slots-next-week]", "phx-click") == [
             "next_week"
           ]

    assert Floki.attribute(doc, "[data-testid=next-slots-next-week]", "data-intent") == ["later"]
  end

  # A visitor whose week still has free times (a Saturday with weekend
  # times) must still be able to reach the next one.
  test "offers the next week after the last day shown, whatever the week holds" do
    doc = render_slots()

    assert slots(doc, "[data-fact=slot]") != []

    assert Floki.attribute(doc, "[data-testid=next-slots-next-week]", "phx-click") == [
             "next_week"
           ]

    [root] = Floki.find(doc, "[data-testid=next-slots]")
    {_tag, _attrs, children} = root

    classes =
      Enum.flat_map(children, fn
        {_tag, _attrs, _children} = child -> Floki.attribute(child, "class")
        _text -> []
      end)

    assert List.last(classes) =~ "next-slots__next-week"
    assert Enum.find_index(classes, &(&1 =~ "next-slots__days")) < length(classes) - 1
  end

  test "marks only the control that moves the week as a period arrow" do
    doc = render_slots()

    assert [{"button", _attrs, _children}] = Floki.find(doc, "[data-intent]")
    assert Floki.attribute(doc, "[data-testid=next-slots-next-week]", "data-intent") == ["later"]
    assert Floki.attribute(doc, "[data-testid=next-slots-more]", "data-intent") == []
  end

  test "offers no slot fact for a day before today" do
    doc = render_slots()

    assert Floki.find(doc, "[data-fact=slot][data-date='2027-03-08']") == []
    assert Enum.all?(Floki.attribute(doc, "[data-fact=slot]", "data-date"), &(&1 >= "2027-03-10"))
  end

  test "shows the week's fetch error" do
    doc = render_slots(error: "No time slots could be loaded. Please try again.")

    assert doc |> Floki.find(".next-slots__error") |> Floki.text() =~
             "No time slots could be loaded. Please try again."
  end
end
