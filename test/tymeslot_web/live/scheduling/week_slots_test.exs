defmodule TymeslotWeb.Live.Scheduling.WeekSlotsTest do
  @moduledoc """
  The week-of-slots lifecycle on a socket: when a week is asked for, when it
  is fetched again, and which results are applied. The socket here is not
  connected, so `start_async/3` starts no task: each test observes the assigns
  a fetch leaves behind, and hands `handle_async/3` the result a task would
  have delivered. The fetch through a real booking page is
  `WeekSlotsFlowTest`'s.
  """
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :unit

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.WeekSlots

  @week ~D[2027-03-08]
  @next_week ~D[2027-03-15]
  @slots %{"2027-03-08" => ["9:00 AM"]}

  defp socket(assigns) do
    %Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            organizer_profile: %{user_id: 1, timezone: "Etc/UTC"},
            user_timezone: "Etc/UTC",
            current_week_start: @week,
            week_slots: nil,
            week_slots_start: nil,
            week_slots_loading: false,
            week_slots_error: nil
          },
          assigns
        )
    }
  end

  defp asked(assigns),
    do:
      socket(
        Map.merge(%{week_slots: %{}, week_slots_start: @week, week_slots_loading: true}, assigns)
      )

  test "a page starts with no week asked for" do
    socket = WeekSlots.assign_defaults(%Socket{assigns: %{__changed__: %{}}})

    assert socket.assigns.week_slots == nil
    assert socket.assigns.week_slots_start == nil
    assert socket.assigns.week_slots_loading == false
    assert socket.assigns.week_slots_error == nil
  end

  describe "load/1" do
    test "asks for the week on screen" do
      socket = WeekSlots.load(socket(%{}))

      assert socket.assigns.week_slots == %{}
      assert socket.assigns.week_slots_start == @week
      assert socket.assigns.week_slots_loading
    end

    test "asks only once, however often the grid sends it" do
      socket = asked(%{})

      assert WeekSlots.load(socket) == socket
    end
  end

  describe "refetch/1" do
    test "does nothing for a page that never asked for a week" do
      socket = socket(%{})

      assert WeekSlots.refetch(socket) == socket
    end

    test "keeps the week on screen while the same week is fetched again" do
      socket =
        WeekSlots.refetch(
          socket(%{week_slots: @slots, week_slots_start: @week, week_slots_error: "Failed"})
        )

      assert socket.assigns.week_slots == @slots
      assert socket.assigns.week_slots_loading
      assert socket.assigns.week_slots_error == nil
    end

    test "empties the grid for another week" do
      socket =
        WeekSlots.refetch(
          socket(%{week_slots: @slots, week_slots_start: @week, current_week_start: @next_week})
        )

      assert socket.assigns.week_slots == %{}
      assert socket.assigns.week_slots_start == @next_week
      assert socket.assigns.week_slots_loading
    end
  end

  describe "follow_week/1" do
    test "leaves a week that is still the one on screen" do
      socket = socket(%{week_slots: @slots, week_slots_start: @week})

      assert WeekSlots.follow_week(socket) == socket
    end

    test "fetches the week the page has moved to" do
      socket =
        WeekSlots.follow_week(
          socket(%{week_slots: @slots, week_slots_start: @week, current_week_start: @next_week})
        )

      assert socket.assigns.week_slots_start == @next_week
      assert socket.assigns.week_slots_loading
    end

    test "does nothing for a page that never asked for a week" do
      socket = socket(%{current_week_start: @next_week})

      assert WeekSlots.follow_week(socket) == socket
    end
  end

  describe "free_days/2" do
    test "lists the days from today on with a free time, in date order" do
      week = %{
        "2027-03-12" => ["2:00 PM"],
        "2027-03-08" => ["9:00 AM"],
        "2027-03-10" => [%{time: "9:00 AM", available: true}],
        "2027-03-11" => []
      }

      assert [
               %{iso: "2027-03-10", date: ~D[2027-03-10], slots: ["9:00 AM"]},
               %{iso: "2027-03-12"}
             ] =
               WeekSlots.free_days(week, ~D[2027-03-10])
    end

    test "is empty when no week is loaded" do
      assert WeekSlots.free_days(nil, ~D[2027-03-10]) == []
    end
  end

  describe "offered?/3" do
    test "is true for a time the loaded week offers on that day" do
      assert WeekSlots.offered?(%{week_slots: @slots}, "2027-03-08", "9:00 AM")
    end

    test "is false for a time on another day, a time not offered, or no week" do
      refute WeekSlots.offered?(%{week_slots: @slots}, "2027-03-09", "9:00 AM")
      refute WeekSlots.offered?(%{week_slots: @slots}, "2027-03-08", "9:15 AM")
      refute WeekSlots.offered?(%{week_slots: nil}, "2027-03-08", "9:00 AM")
    end

    test "reads the demo provider's slot maps as it reads plain times" do
      assert WeekSlots.offered?(
               %{week_slots: %{"2027-03-08" => [%{time: "9:00 AM", available: true}]}},
               "2027-03-08",
               "9:00 AM"
             )
    end
  end

  describe "handle_async/3" do
    test "applies the result for the week last asked for" do
      assert {:noreply, socket} =
               WeekSlots.handle_async({:week_slots, @week}, {:ok, {:ok, @slots}}, asked(%{}))

      assert socket.assigns.week_slots == @slots
      refute socket.assigns.week_slots_loading
      assert socket.assigns.week_slots_error == nil
    end

    test "discards a result for a week the booker has left" do
      socket = asked(%{week_slots_start: @next_week, current_week_start: @next_week})

      assert {:noreply, ^socket} =
               WeekSlots.handle_async({:week_slots, @week}, {:ok, {:ok, @slots}}, socket)
    end

    test "discards the exit a cancelled fetch reports" do
      socket = asked(%{week_slots_start: @next_week, current_week_start: @next_week})

      assert {:noreply, ^socket} =
               WeekSlots.handle_async({:week_slots, @week}, {:exit, {:shutdown, :cancel}}, socket)
    end

    test "discards a result once nothing is on its way" do
      socket = socket(%{week_slots: @slots, week_slots_start: @week})

      assert {:noreply, ^socket} =
               WeekSlots.handle_async({:week_slots, @week}, {:ok, {:ok, %{}}}, socket)
    end

    @tag :capture_log
    test "shows a failed fetch, keeping what was on screen" do
      assert {:noreply, socket} =
               WeekSlots.handle_async(
                 {:week_slots, @week},
                 {:ok, {:error, :timeout}},
                 asked(%{week_slots: @slots})
               )

      assert socket.assigns.week_slots == @slots
      refute socket.assigns.week_slots_loading
      assert socket.assigns.week_slots_error == "No time slots could be loaded. Please try again."
    end

    @tag :capture_log
    test "shows a fetch that crashed" do
      assert {:noreply, socket} =
               WeekSlots.handle_async({:week_slots, @week}, {:exit, :boom}, asked(%{}))

      refute socket.assigns.week_slots_loading
      assert socket.assigns.week_slots_error == "No time slots could be loaded. Please try again."
    end

    test "leaves a result of any other name to its caller" do
      assert WeekSlots.handle_async(:something_else, {:ok, :done}, asked(%{})) == :unhandled
    end
  end
end
