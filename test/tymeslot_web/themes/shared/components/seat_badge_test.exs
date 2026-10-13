defmodule TymeslotWeb.Themes.Shared.Components.SeatBadgeTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :themes
  @moduletag :components
  @moduletag :unit

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.Components.SeatBadge

  @defaults %{show_seat_availability: true, last_spots_threshold: nil}

  defp badge(slot, settings \\ %{}) do
    display = SeatBadge.display(slot, Map.merge(@defaults, settings))
    render_component(&SeatBadge.seat_badge/1, %{display: display})
  end

  test "renders nothing for solo slots (seats_left nil)" do
    html = badge(%{seats_left: nil, capacity: nil})
    refute html =~ "seat-badge"
  end

  test "green above half the spots names the level in words (6 of 10)" do
    html = badge(%{seats_left: 6, capacity: 10})
    assert html =~ "seat-green"
    assert html =~ "Plenty left"
    refute html =~ "spots left"
    assert html =~ ~s(data-testid="seat-badge")
  end

  test "amber at half or fewer (5 of 10)" do
    html = badge(%{seats_left: 5, capacity: 10})
    assert html =~ "seat-amber"
    assert html =~ "Filling up"
  end

  test "red at twenty percent or fewer (2 of 10)" do
    html = badge(%{seats_left: 2, capacity: 10})
    assert html =~ "seat-red"
    assert html =~ "Almost full"
  end

  test "within the last-spots threshold the count replaces the level label" do
    html = badge(%{seats_left: 1, capacity: 10}, %{last_spots_threshold: 3})
    assert html =~ "seat-red"
    assert html =~ "1 spot left"
    refute html =~ "1 spots left"
    refute html =~ "Almost full"
  end

  test "with colours off the count is neutral" do
    html =
      badge(%{seats_left: 3, capacity: 10}, %{
        show_seat_availability: false,
        last_spots_threshold: 3
      })

    assert html =~ "seat-neutral"
    assert html =~ "3 spots left"
  end

  test "with colours off and above the threshold nothing renders" do
    html =
      badge(%{seats_left: 4, capacity: 10}, %{
        show_seat_availability: false,
        last_spots_threshold: 3
      })

    refute html =~ "seat-badge"
  end

  test "a plain-map meeting type without the settings reads as the defaults" do
    html =
      render_component(&SeatBadge.seat_badge/1, %{
        display: SeatBadge.display(%{seats_left: 6, capacity: 10}, %{max_participants: 10})
      })

    assert html =~ "Plenty left"
  end
end
