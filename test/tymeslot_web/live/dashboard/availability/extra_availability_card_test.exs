defmodule TymeslotWeb.Dashboard.Availability.ExtraAvailabilityCardTest do
  @moduledoc """
  Covers the extra available times card in the schedule panel: adding a time
  through the form, refusing an overlapping one, and removing one.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Availability.{ExtraAvailability, Schedules}
  alias Tymeslot.Infrastructure.AvailabilityCache

  setup %{conn: conn} do
    AvailabilityCache.clear_all()
    {:ok, ctx} = setup_dashboard_user(%{conn: conn})
    {:ok, schedule} = Schedules.create_default(ctx[:profile].id)
    Keyword.put(ctx, :schedule, schedule)
  end

  test "adds times through the form, refuses an overlap and removes one", %{
    conn: conn,
    schedule: schedule
  } do
    date = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()
    {:ok, view, html} = live(conn, ~p"/dashboard/availability")

    assert html =~ "Extra available times"
    assert html =~ "No extra times added."

    for {from, to} <- [{"14:00", "16:00"}, {"09:00", "11:00"}] do
      view
      |> form("[data-testid='extra-availability-form']", %{
        "extra" => %{"date" => date, "start_time" => from, "end_time" => to}
      })
      |> render_submit()
    end

    assert [_one_day] =
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[data-testid='extra-availability-day']")

    assert length(ExtraAvailability.list_upcoming(schedule.id, Date.utc_today())) == 2

    html =
      view
      |> form("[data-testid='extra-availability-form']", %{
        "extra" => %{"date" => date, "start_time" => "10:00", "end_time" => "12:00"}
      })
      |> render_submit()

    assert html =~ "This time overlaps another extra time on that date."

    [first | _rest] = ExtraAvailability.list_upcoming(schedule.id, Date.utc_today())

    view
    |> element("[data-testid='extra-availability-remove'][phx-value-id='#{first.id}']")
    |> render_click()

    assert length(ExtraAvailability.list_upcoming(schedule.id, Date.utc_today())) == 1
  end
end
