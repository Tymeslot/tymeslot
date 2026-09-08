defmodule TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent

  test "handle_timezone_change updates state" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "UTC",
        selected_time: "10:00",
        available_slots: ["10:00"],
        timezone_dropdown_open: true,
        timezone_search: "Lon",
        selected_date: nil
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Europe/London")
    assert updated.assigns.user_timezone == "Europe/London"
    assert updated.assigns.selected_time == nil
    assert updated.assigns.timezone_dropdown_open == false
    assert updated.assigns.timezone_search == ""
  end

  test "handle_timezone_change triggers slot reload if date is selected" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "UTC",
        selected_date: ~D[2024-01-01],
        selected_duration: 30,
        duration: nil,
        selected_time: "10:00",
        available_slots: ["10:00"],
        timezone_dropdown_open: true,
        timezone_search: "Lon"
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Europe/London")
    assert updated.assigns.loading_slots == true
    assert_receive {:fetch_available_slots, ~D[2024-01-01], 30, "Europe/London"}
  end
end
