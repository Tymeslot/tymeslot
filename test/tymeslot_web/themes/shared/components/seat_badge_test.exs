defmodule TymeslotWeb.Themes.Shared.Components.SeatBadgeTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :themes
  @moduletag :components
  @moduletag :unit

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.Components.SeatBadge

  defp badge(assigns), do: render_component(&SeatBadge.seat_badge/1, assigns)

  test "renders nothing for solo slots (seats_left nil)" do
    html = badge(%{seats_left: nil, capacity: nil})
    refute html =~ "seat-badge"
  end

  test "green above half the seats (6 of 10)" do
    html = badge(%{seats_left: 6, capacity: 10})
    assert html =~ "seat-green"
    assert html =~ "6 seats left"
    assert html =~ ~s(data-testid="seat-badge")
  end

  test "amber at half or fewer (5 of 10)" do
    assert badge(%{seats_left: 5, capacity: 10}) =~ "seat-amber"
  end

  test "red at twenty percent or fewer (2 of 10)" do
    assert badge(%{seats_left: 2, capacity: 10}) =~ "seat-red"
  end

  test "red and singular copy for the last seat" do
    html = badge(%{seats_left: 1, capacity: 10})
    assert html =~ "seat-red"
    assert html =~ "1 seat left"
    refute html =~ "1 seats left"
  end
end
