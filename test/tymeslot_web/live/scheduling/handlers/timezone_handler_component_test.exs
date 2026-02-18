defmodule TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent

  test "handle_timezone_dropdown_toggle toggles state" do
    socket = %Socket{assigns: %{__changed__: %{}, timezone_dropdown_open: false}}
    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_dropdown_toggle(socket)
    assert updated.assigns.timezone_dropdown_open == true

    {:ok, updated_again} = TimezoneHandlerComponent.handle_timezone_dropdown_toggle(updated)
    assert updated_again.assigns.timezone_dropdown_open == false
  end

  test "handle_timezone_dropdown_close closes dropdown" do
    socket = %Socket{assigns: %{__changed__: %{}, timezone_dropdown_open: true}}
    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_dropdown_close(socket)
    assert updated.assigns.timezone_dropdown_open == false
  end

  test "handle_timezone_search updates search term from different param formats" do
    socket = %Socket{assigns: %{__changed__: %{}}}

    {:ok, updated} =
      TimezoneHandlerComponent.handle_timezone_search(socket, %{"search" => "London"})

    assert updated.assigns.timezone_search == "London"

    {:ok, updated} =
      TimezoneHandlerComponent.handle_timezone_search(socket, %{"value" => "Paris"})

    assert updated.assigns.timezone_search == "Paris"

    {:ok, updated} =
      TimezoneHandlerComponent.handle_timezone_search(socket, %{
        "_target" => ["search"],
        "search" => "Berlin"
      })

    assert updated.assigns.timezone_search == "Berlin"
  end

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
