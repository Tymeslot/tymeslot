defmodule TymeslotWeb.Themes.Shared.Blocks.AgendaIndexTest do
  @moduledoc """
  The week as an index: a row per day from today with a free time, its times
  as text buttons. The clock is frozen on Wednesday 10 March 2027, in the week
  from Monday 8 March.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.Test.ClockHelpers
  alias TymeslotWeb.Themes.Shared.Blocks.AgendaIndex

  @week %{
    "2027-03-08" => ["9:00 AM"],
    "2027-03-10" => ["9:00 AM"],
    "2027-03-11" => [],
    "2027-03-12" => ["2:00 PM", "2:30 PM"]
  }

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    ClockHelpers.freeze_clock(~U[2027-03-10 12:00:00Z])
    :ok
  end

  defp render_index(overrides \\ []) do
    assigns =
      Map.merge(
        %{
          week_start: ~D[2027-03-08],
          week_slots: @week,
          user_timezone: "Etc/UTC",
          booking_window_days: 30,
          target: nil
        },
        Map.new(overrides)
      )

    (&AgendaIndex.agenda_index/1)
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  test "lists a row per day from today with a free time" do
    assert Floki.attribute(render_index(), ".agenda-index__row", "data-date") ==
             ["2027-03-10", "2027-03-12"]
  end

  test "takes today from the visitor's timezone, not the UTC date" do
    # 23:30 UTC on 10 March is already 11 March in Tokyo, so the 10th is past.
    ClockHelpers.freeze_clock(~U[2027-03-10 23:30:00Z])
    doc = render_index(user_timezone: "Asia/Tokyo")

    assert Floki.attribute(doc, ".agenda-index__row", "data-date") == ["2027-03-12"]

    ClockHelpers.freeze_clock(~U[2027-03-11 23:30:00Z])
    doc = render_index(user_timezone: "Asia/Tokyo")

    assert doc |> Floki.find(".agenda-index__row") |> hd() |> Floki.text() =~ "Today"
  end

  test "offers each row's times as slot facts" do
    doc = render_index()

    assert Floki.attribute(doc, "[data-date='2027-03-12'][data-fact=slot]", "data-time") ==
             ["2:00 PM", "2:30 PM"]

    assert Floki.attribute(doc, "[data-time='2:30 PM'][data-fact=slot]", "phx-click") ==
             ["select_slot"]
  end

  test "goes back no earlier than this week, and on within the booking window" do
    doc = render_index()

    assert Floki.attribute(doc, "[data-testid=agenda-index-prev]", "disabled") != []
    assert Floki.attribute(doc, "[data-testid=agenda-index-next]", "disabled") == []
    assert Floki.attribute(doc, "[data-testid=agenda-index-next]", "phx-click") == ["next_week"]
  end

  test "marks the week controls as the period arrows of the markup contract" do
    doc = render_index()

    assert Floki.attribute(doc, "[data-testid=agenda-index-prev]", "data-intent") == ["earlier"]
    assert Floki.attribute(doc, "[data-testid=agenda-index-next]", "data-intent") == ["later"]
  end

  test "offers no slot fact for a day before today" do
    doc = render_index()

    assert Floki.find(doc, "[data-fact=slot][data-date='2027-03-08']") == []
  end

  test "asks for its week while it has none" do
    doc = render_index(week_slots: nil)

    assert [mounted] = Floki.attribute(doc, "[data-testid=agenda-index]", "phx-mounted")
    assert mounted =~ "load_week"
  end

  test "says it is loading, not empty, while another week's slots are fetched" do
    doc = render_index(week_slots: %{}, loading: true)

    assert doc |> Floki.find(".agenda-index__loading") |> Floki.text() =~
             "Loading available times"

    assert Floki.find(doc, ".agenda-index__empty") == []
  end

  test "keeps the rows while the week shown is fetched again" do
    doc = render_index(loading: true)

    assert Floki.attribute(doc, ".agenda-index__row", "data-date") == ["2027-03-10", "2027-03-12"]
    assert Floki.find(doc, ".agenda-index__loading") == []
  end

  test "says when the week has nothing free from today on" do
    doc = render_index(week_slots: %{"2027-03-08" => ["9:00 AM"]})

    assert Floki.find(doc, ".agenda-index__row") == []
    assert doc |> Floki.find(".agenda-index__empty") |> Floki.text() =~ "No times available"
  end
end
