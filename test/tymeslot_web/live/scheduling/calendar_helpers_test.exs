defmodule TymeslotWeb.Live.Scheduling.CalendarHelpersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling

  import Tymeslot.Test.ClockHelpers

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers

  describe "handle_month_navigation/2" do
    defp month_socket(year, month) do
      %Socket{
        assigns: %{
          __changed__: %{},
          current_year: year,
          current_month: month,
          selected_date: "#{year}-#{String.pad_leading("#{month}", 2, "0")}-03",
          selected_time: "10:00",
          available_slots: ["10:00"],
          month_availability_map: %{},
          availability_status: :loaded
        }
      }
    end

    test "steps forward into the next year" do
      socket = CalendarHelpers.handle_month_navigation(month_socket(2027, 12), :next)
      assert {socket.assigns.current_year, socket.assigns.current_month} == {2028, 1}
    end

    test "steps back into the previous year" do
      socket = CalendarHelpers.handle_month_navigation(month_socket(2027, 1), :prev)
      assert {socket.assigns.current_year, socket.assigns.current_month} == {2026, 12}
    end

    test "drops the day and time picked in the month being left, and its availability" do
      socket = CalendarHelpers.handle_month_navigation(month_socket(2027, 6), :next)

      assert %{
               selected_date: nil,
               selected_time: nil,
               available_slots: [],
               month_availability_map: nil,
               availability_status: :not_loaded
             } = socket.assigns
    end
  end

  describe "anchor_on_today/1" do
    test "opens on the visitor's date when it is already tomorrow there" do
      freeze_clock(~U[2027-01-31 12:00:00Z])

      socket =
        CalendarHelpers.anchor_on_today(calendar_socket(%{user_timezone: "Pacific/Kiritimati"}))

      assert %{
               calendar_today: ~D[2027-02-01],
               current_year: 2027,
               current_month: 2,
               current_week_start: ~D[2027-02-01]
             } = socket.assigns
    end

    test "opens on the week that starts on the visitor's week start" do
      freeze_clock(~U[2027-02-03 12:00:00Z])

      socket =
        CalendarHelpers.anchor_on_today(
          calendar_socket(%{user_timezone: "Etc/UTC", week_start: :sunday})
        )

      assert socket.assigns.current_week_start == ~D[2027-01-31]
      assert socket.assigns.calendar_landing.current_week_start == ~D[2027-01-31]
      assert CalendarHelpers.untouched?(socket.assigns)
    end

    test "opens on the visitor's date when it is still yesterday there" do
      freeze_clock(~U[2027-02-01 05:00:00Z])

      socket =
        CalendarHelpers.anchor_on_today(calendar_socket(%{user_timezone: "Pacific/Pago_Pago"}))

      assert %{
               calendar_today: ~D[2027-01-31],
               current_year: 2027,
               current_month: 1,
               current_week_start: ~D[2027-01-25]
             } = socket.assigns
    end
  end

  describe "untouched?/1" do
    setup do
      freeze_clock(~U[2027-01-31 12:00:00Z])
      :ok
    end

    test "holds for a calendar still on the day it opened on, with no day chosen" do
      assert CalendarHelpers.untouched?(opened_in_tallinn(%{}).assigns)
    end

    test "fails once the booker has moved the month" do
      refute CalendarHelpers.untouched?(opened_in_tallinn(%{current_month: 3}).assigns)
    end

    test "fails once the booker has moved the week" do
      refute CalendarHelpers.untouched?(
               opened_in_tallinn(%{current_week_start: ~D[2027-02-01]}).assigns
             )
    end

    test "fails once the booker has chosen a day" do
      refute CalendarHelpers.untouched?(opened_in_tallinn(%{selected_date: "2027-02-03"}).assigns)
    end

    test "treats a blank selection as none" do
      assert CalendarHelpers.untouched?(opened_in_tallinn(%{selected_date: ""}).assigns)
    end

    test "fails for a calendar the page never placed" do
      refute CalendarHelpers.untouched?(calendar_socket(%{}).assigns)
    end
  end

  describe "selection_out_of_window?/1" do
    # Sunday 31 January in Tallinn, already Monday 1 February in Kiritimati.
    setup do
      freeze_clock(~U[2027-01-31 12:00:00Z])
      :ok
    end

    test "holds for a day already past in the booker's timezone" do
      assert CalendarHelpers.selection_out_of_window?(
               window_socket(%{user_timezone: "Pacific/Kiritimati", selected_date: "2027-01-31"}).assigns
             )
    end

    test "fails for the same day where it is still today" do
      refute CalendarHelpers.selection_out_of_window?(
               window_socket(%{selected_date: "2027-01-31"}).assigns
             )
    end

    test "holds for a day past the booking window" do
      assert CalendarHelpers.selection_out_of_window?(
               window_socket(%{selected_date: "2027-05-02"}).assigns
             )
    end

    test "fails with no day selected" do
      refute CalendarHelpers.selection_out_of_window?(window_socket(%{}).assigns)
    end
  end

  describe "land_on/2" do
    setup do
      freeze_clock(~U[2027-01-31 12:00:00Z])
      :ok
    end

    # The page's own pick: `NextAvailable` selects the day, then lands on it.
    defp landed_on(date) do
      socket = opened_in_tallinn(%{selected_date: Date.to_iso8601(date)})
      CalendarHelpers.land_on(socket, date)
    end

    test "moves the month and week onto the day and leaves the calendar untouched" do
      socket = landed_on(~D[2027-03-10])

      assert %{current_year: 2027, current_month: 3, current_week_start: ~D[2027-03-08]} =
               socket.assigns

      assert CalendarHelpers.untouched?(socket.assigns)
    end

    test "a day the booker clicks afterwards is theirs" do
      socket = landed_on(~D[2027-03-10])

      refute CalendarHelpers.untouched?(Map.put(socket.assigns, :selected_date, "2027-03-11"))
    end

    test "a week the booker moves to afterwards is theirs" do
      socket = landed_on(~D[2027-03-10])

      refute CalendarHelpers.untouched?(
               Map.put(socket.assigns, :current_week_start, ~D[2027-03-15])
             )
    end

    test "a day linked with ?date= is not the page's, however it is opened" do
      # `anchor_on_selection/1` opens a linked day with `anchor_on/2`, which
      # moves the calendar without claiming the position.
      socket =
        CalendarHelpers.anchor_on_selection(
          window_socket(%{selected_date: "2027-01-31", selected_time: nil})
        )

      assert socket.assigns.selected_date == "2027-01-31"
      refute CalendarHelpers.untouched?(socket.assigns)
    end
  end

  describe "anchor_on/2" do
    test "moves the month and the Monday-started week onto the date" do
      socket = CalendarHelpers.anchor_on(calendar_socket(%{}), ~D[2027-03-10])

      assert %{current_year: 2027, current_month: 3, current_week_start: ~D[2027-03-08]} =
               socket.assigns
    end
  end

  describe "anchor_on_selection/1" do
    setup do
      freeze_clock(~U[2027-01-31 12:00:00Z])
      :ok
    end

    test "opens on a chosen day in a later month, week included" do
      socket =
        CalendarHelpers.anchor_on_selection(
          window_socket(%{selected_date: "2027-03-10", selected_time: "10:00 AM"})
        )

      assert %{
               calendar_today: ~D[2027-01-31],
               current_year: 2027,
               current_month: 3,
               current_week_start: ~D[2027-03-08],
               selected_date: "2027-03-10",
               selected_time: "10:00 AM"
             } = socket.assigns
    end

    test "keeps the last day of the booking window" do
      socket = CalendarHelpers.anchor_on_selection(window_socket(%{selected_date: "2027-05-01"}))

      assert %{current_month: 5, current_week_start: ~D[2027-04-26], selected_date: "2027-05-01"} =
               socket.assigns
    end

    test "drops a day before today and opens on today" do
      socket =
        CalendarHelpers.anchor_on_selection(
          window_socket(%{selected_date: "2027-01-30", selected_time: "10:00 AM"})
        )

      assert %{
               current_month: 1,
               current_week_start: ~D[2027-01-25],
               selected_date: nil,
               selected_time: nil
             } = socket.assigns
    end

    test "drops a day past the booking window and opens on today" do
      socket = CalendarHelpers.anchor_on_selection(window_socket(%{selected_date: "2027-05-02"}))

      assert %{current_month: 1, current_week_start: ~D[2027-01-25], selected_date: nil} =
               socket.assigns
    end

    test "judges the day in the visitor's timezone" do
      # Still Sunday 31 January in UTC, but already 1 February in Kiritimati.
      socket =
        CalendarHelpers.anchor_on_selection(
          window_socket(%{user_timezone: "Pacific/Kiritimati", selected_date: "2027-01-31"})
        )

      assert %{calendar_today: ~D[2027-02-01], current_month: 2, selected_date: nil} =
               socket.assigns
    end

    test "with no day chosen, opens on today like anchor_on_today/1" do
      socket = CalendarHelpers.anchor_on_selection(window_socket(%{}))

      assert %{
               calendar_today: ~D[2027-01-31],
               current_month: 1,
               current_week_start: ~D[2027-01-25],
               selected_date: nil
             } = socket.assigns
    end
  end

  # A socket with no organiser, so a month availability fetch stands down.
  defp calendar_socket(assigns) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}, selected_date: nil, week_start: :monday}, assigns)
    }
  end

  # A calendar in Tallinn whose meeting type allows booking 90 days ahead.
  defp window_socket(assigns) do
    calendar_socket(
      Map.merge(
        %{user_timezone: "Europe/Tallinn", booking_window_days: 90, selected_time: nil},
        assigns
      )
    )
  end

  # A calendar the page opened in Tallinn. `changes` stands for what the
  # booker did afterwards.
  defp opened_in_tallinn(changes) do
    socket = CalendarHelpers.anchor_on_today(calendar_socket(%{user_timezone: "Europe/Tallinn"}))
    %{socket | assigns: Map.merge(socket.assigns, changes)}
  end
end
