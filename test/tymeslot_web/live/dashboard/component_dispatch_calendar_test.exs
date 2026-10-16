defmodule TymeslotWeb.Dashboard.ComponentDispatchCalendarTest do
  @moduledoc """
  The per-user switch between the old calendar grid and the redesigned
  surface, as `ComponentDispatch` resolves it.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.CalendarGridComponent
  alias TymeslotWeb.Dashboard.ComponentDispatch
  alias TymeslotWeb.Dashboard.DashboardOverviewComponent

  test "the calendar keeps the old grid unless the switch is on" do
    assert ComponentDispatch.component_for_action(:calendar, %{}) == CalendarGridComponent

    assert ComponentDispatch.component_for_action(:calendar, %{}, calendar_redesign: false) ==
             CalendarGridComponent
  end

  test "the switch picks the new surface" do
    assert ComponentDispatch.component_for_action(:calendar, %{}, calendar_redesign: true) ==
             CalendarSurface
  end

  test "the switch leaves every other section alone" do
    assert ComponentDispatch.component_for_action(:overview, %{}, calendar_redesign: true) ==
             DashboardOverviewComponent
  end

  test "calendar_component/1 names the module calendar updates go to" do
    assert ComponentDispatch.calendar_component(true) == CalendarSurface
    assert ComponentDispatch.calendar_component(false) == CalendarGridComponent
  end
end
