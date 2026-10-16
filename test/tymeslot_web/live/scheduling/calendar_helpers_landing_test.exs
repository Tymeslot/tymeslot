defmodule TymeslotWeb.Live.Scheduling.CalendarHelpersLandingTest do
  @moduledoc """
  Where the page landed the booker on the calendar, and the way back to it:
  `CalendarHelpers.landing_week/1` and `return_to_landing/1`.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers

  describe "landing_week/1" do
    test "is the week of the day the page landed the booker on" do
      assert CalendarHelpers.landing_week(%{calendar_landing: landing("2027-03-10")}) ==
               ~D[2027-03-08]
    end

    test "is nil when the page landed on no day, or has not placed the calendar" do
      assert CalendarHelpers.landing_week(%{calendar_landing: landing(nil)}) == nil
      assert CalendarHelpers.landing_week(%{}) == nil
    end
  end

  describe "return_to_landing/1" do
    test "moves the month and the week back, keeping the booker's selection" do
      socket =
        CalendarHelpers.return_to_landing(
          landed_socket(%{
            current_week_start: ~D[2027-03-22],
            selected_date: "2027-03-24",
            selected_time: "10:00 AM"
          })
        )

      assert %{
               current_year: 2027,
               current_month: 3,
               current_week_start: ~D[2027-03-08],
               selected_date: "2027-03-24",
               selected_time: "10:00 AM"
             } = socket.assigns
    end

    test "drops the month's availability when it returns to another month" do
      socket =
        CalendarHelpers.return_to_landing(
          landed_socket(%{
            current_month: 4,
            current_week_start: ~D[2027-04-05],
            month_availability_map: %{"2027-04-05" => true},
            availability_status: :loaded
          })
        )

      assert %{current_month: 3, month_availability_map: nil, availability_status: :not_loaded} =
               socket.assigns
    end

    test "leaves a calendar the page landed on no day as it is" do
      socket =
        landed_socket(%{calendar_landing: landing(nil), current_week_start: ~D[2027-03-22]})

      assert CalendarHelpers.return_to_landing(socket) == socket
    end
  end

  defp landing(selected_date),
    do: %{
      current_year: 2027,
      current_month: 3,
      current_week_start: ~D[2027-03-08],
      selected_date: selected_date
    }

  defp landed_socket(assigns) do
    %Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            calendar_landing: landing("2027-03-10"),
            current_year: 2027,
            current_month: 3
          },
          assigns
        )
    }
  end
end
