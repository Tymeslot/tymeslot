defmodule TymeslotWeb.Themes.Shared.Journey.Facts.SlotTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Slot

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  test "is the slot, needed by every booking once the meeting type is known" do
    assert Slot.key() == :slot
    assert Slot.requires(%{}) == [:meeting_type]
    assert Slot.required?(%{})

    assert Slot.events() == [
             :select_date,
             :select_time,
             :toggle_hour,
             :prev_week,
             :next_week,
             :load_week,
             :select_slot,
             :first_available_week,
             :prev_month,
             :next_month
           ]
  end

  describe "known?/1 and continue/1" do
    test "a day and a time let the booker on" do
      socket = socket(%{selected_date: "2027-01-05", selected_time: "10:00", available_slots: []})

      assert Slot.known?(socket.assigns)
      assert Slot.continue(socket) == {:done, socket}
    end

    test "without a day or without a time, says which is missing" do
      no_day = socket(%{selected_date: nil, selected_time: nil, available_slots: []})
      no_time = socket(%{selected_date: "2027-01-05", selected_time: nil, available_slots: []})

      refute Slot.known?(no_day.assigns)
      assert Slot.continue(no_day) == {:error, :date_required}
      assert Slot.continue(no_time) == {:error, :time_required}
    end
  end

  describe "slot events" do
    test "picking a day clears the time and the hour grouping, and loads that day's slots" do
      socket =
        socket(%{selected_date: "2027-01-04", selected_time: "10:00", expanded_hour: :none})

      assert {:noreply, socket} = Slot.handle(socket, :select_date, "2027-01-05")

      assert %{selected_date: "2027-01-05", selected_time: nil, expanded_hour: nil} =
               socket.assigns

      assert socket.assigns.loading_slots
      assert_received {:load_slots, "2027-01-05"}
    end

    test "picking the chosen time again unchooses it" do
      socket = socket(%{selected_time: "10:00"})

      assert {:noreply, socket} = Slot.handle(socket, :select_time, "10:00")

      assert socket.assigns.selected_time == nil
    end

    test "a non-string hour is ignored rather than crashing the page" do
      socket = socket(%{expanded_hour: 11})

      assert {:noreply, ^socket} = Slot.handle(socket, :toggle_hour, 11)
    end

    test "month navigation is a shared schedule event, not a theme's" do
      socket = socket(%{current_year: 2027, current_month: 12})

      assert {:noreply, socket} = Slot.handle(socket, :next_month, nil)

      assert {socket.assigns.current_year, socket.assigns.current_month} == {2028, 1}
    end

    test "a week view asks for the week on screen with load_week" do
      socket =
        socket(%{
          organizer_profile: %{user_id: 1},
          user_timezone: "Etc/UTC",
          current_week_start: ~D[2027-01-04],
          week_slots: nil,
          week_slots_start: nil,
          week_slots_loading: false
        })

      assert {:noreply, socket} = Slot.handle(socket, :load_week, nil)

      assert socket.assigns.week_slots_start == ~D[2027-01-04]
      assert socket.assigns.week_slots_loading
    end

    test "week navigation fetches the week moved to only for a page showing one" do
      base = %{
        organizer_profile: %{user_id: 1},
        user_timezone: "Etc/UTC",
        current_year: 2027,
        current_month: 1,
        current_week_start: ~D[2027-01-04],
        week_slots_loading: false,
        week_slots_error: nil
      }

      assert {:noreply, without} =
               base
               |> Map.merge(%{week_slots: nil, week_slots_start: nil})
               |> socket()
               |> Slot.handle(:next_week, nil)

      assert without.assigns.current_week_start == ~D[2027-01-11]
      assert without.assigns.week_slots == nil

      assert {:noreply, shown} =
               base
               |> Map.merge(%{week_slots: %{}, week_slots_start: ~D[2027-01-04]})
               |> socket()
               |> Slot.handle(:next_week, nil)

      assert shown.assigns.week_slots_start == ~D[2027-01-11]
      assert shown.assigns.week_slots_loading
    end

    test "picking a time on the week picks its day too, and loads that day's slots" do
      socket =
        socket(%{
          selected_date: "2027-01-04",
          selected_time: nil,
          expanded_hour: :none,
          user_timezone: "Etc/UTC",
          week_slots: %{"2027-01-05" => ["10:00 AM"]}
        })

      assert {:noreply, socket} = Slot.handle(socket, :select_slot, {"2027-01-05", "10:00 AM"})

      assert %{selected_date: "2027-01-05", selected_time: "10:00 AM", expanded_hour: nil} =
               socket.assigns

      assert socket.assigns.loading_slots
      assert_received {:fetch_available_slots, "2027-01-05", _duration, "Etc/UTC"}
    end

    test "another time on the day already chosen changes only the time" do
      socket =
        socket(%{
          selected_date: "2027-01-05",
          selected_time: "10:00 AM",
          week_slots: %{"2027-01-05" => ["10:00 AM", "11:00 AM"]}
        })

      assert {:noreply, socket} = Slot.handle(socket, :select_slot, {"2027-01-05", "11:00 AM"})
      assert socket.assigns.selected_time == "11:00 AM"

      assert {:noreply, socket} = Slot.handle(socket, :select_slot, {"2027-01-05", "11:00 AM"})
      assert socket.assigns.selected_time == "11:00 AM"
      refute_received {:fetch_available_slots, _date, _duration, _timezone}
    end

    test "a pair the loaded week does not offer picks nothing" do
      socket =
        socket(%{
          selected_date: nil,
          selected_time: nil,
          week_slots: %{"2027-01-05" => ["10:00 AM"]}
        })

      assert {:noreply, ^socket} = Slot.handle(socket, :select_slot, {"2027-01-05", "3:15 AM"})
      assert {:noreply, ^socket} = Slot.handle(socket, :select_slot, {["2027-01-05"], "10:00 AM"})
    end

    test "a time on the week kept on screen during a refetch picks nothing" do
      socket =
        socket(%{
          selected_date: nil,
          selected_time: nil,
          user_timezone: "Asia/Tokyo",
          week_slots: %{"2027-01-05" => ["10:00 AM"]},
          week_slots_loading: true
        })

      assert {:noreply, ^socket} = Slot.handle(socket, :select_slot, {"2027-01-05", "10:00 AM"})

      refute_received {:fetch_available_slots, _date, _duration, _timezone}
    end

    test "the first available week brings the calendar back to where the page landed" do
      socket =
        socket(%{
          calendar_landing: %{
            current_year: 2027,
            current_month: 1,
            current_week_start: ~D[2027-01-04],
            selected_date: "2027-01-05"
          },
          current_year: 2027,
          current_month: 1,
          current_week_start: ~D[2027-01-18],
          week_slots: nil
        })

      assert {:noreply, socket} = Slot.handle(socket, :first_available_week, nil)

      assert socket.assigns.current_week_start == ~D[2027-01-04]
    end
  end
end
