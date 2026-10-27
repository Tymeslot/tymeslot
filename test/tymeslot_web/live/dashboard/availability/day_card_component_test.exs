defmodule TymeslotWeb.Dashboard.Availability.DayCardComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :availability

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.Availability.DayCardComponent

  # The hours selects point at the errors by id, so several messages for one
  # day share a single element rather than repeating the id.
  test "renders every hours error for a day in one element with one id" do
    html =
      render_component(&DayCardComponent.day_card/1,
        day: 1,
        day_availability: %{
          id: 1,
          day_of_week: 1,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00],
          ends_next_day: false,
          breaks: []
        },
        day_name: "Monday",
        break_duration_presets: [],
        form_errors: %{},
        hours_errors: %{1 => %{start: "Start is wrong", end: "End is wrong"}},
        refused_hours: %{},
        show_add_break_form: nil,
        open_menu_day: nil,
        time_format: "24h",
        myself: nil
      )

    assert length(Regex.scan(~r/id="day-hours-errors-1"/, html)) == 1
    assert html =~ "Start is wrong"
    assert html =~ "End is wrong"
  end
end
