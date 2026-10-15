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

  test "handle_timezone_change leaves reloading the selected day's slots to its caller" do
    # The caller first decides whether the day stays selected in the new zone;
    # a reload queued here would fetch slots for a day about to be dropped.
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "UTC",
        selected_date: "2024-01-01",
        selected_duration: 30,
        duration: nil,
        selected_time: "10:00",
        available_slots: ["10:00"],
        timezone_dropdown_open: true,
        timezone_search: "Lon"
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Europe/London")

    assert %{user_timezone: "Europe/London", selected_time: nil, available_slots: []} =
             updated.assigns

    refute_received {:fetch_available_slots, _date, _duration, _timezone}
  end

  test "handle_timezone_change keeps the time and slots when the zone in use is picked again" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "Europe/London",
        selected_date: "2024-01-01",
        selected_time: "10:00",
        available_slots: ["10:00"],
        timezone_dropdown_open: true,
        timezone_search: "Lon"
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Europe/London")

    assert %{selected_time: "10:00", available_slots: ["10:00"], timezone_dropdown_open: false} =
             updated.assigns
  end

  test "handle_timezone_change closes the picker when the zone in use is picked in another spelling" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "Asia/Kolkata",
        selected_date: "2024-01-01",
        selected_time: "10:00",
        available_slots: ["10:00"],
        timezone_dropdown_open: true,
        timezone_search: "Calc"
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Asia/Calcutta")

    assert %{
             user_timezone: "Asia/Kolkata",
             selected_time: "10:00",
             available_slots: ["10:00"],
             timezone_dropdown_open: false,
             timezone_search: ""
           } = updated.assigns
  end

  test "handle_timezone_change leaves everything as it was for a zone that is not one" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "Europe/London",
        selected_time: "10:00",
        available_slots: ["10:00"],
        timezone_dropdown_open: true,
        timezone_search: "Nar"
      }
    }

    {:ok, updated} =
      TimezoneHandlerComponent.handle_timezone_change(socket, "Narnia/Cair_Paravel")

    assert updated.assigns == socket.assigns
  end

  # The picker can be handed a legacy id (a bookmarked `?timezone=`, an old
  # browser). It is stored under its current name, and that must still count
  # as accepted: comparing the stored name with the raw request treated the
  # rename as a rejection, so the old zone's time and slots were kept and the
  # picker stayed open. Reloading the slots is the caller's job (see above).
  test "handle_timezone_change accepts a legacy id under its current name" do
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
        timezone_search: "Kie"
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Europe/Kiev")

    assert %{
             user_timezone: "Europe/Kyiv",
             timezone_dropdown_open: false,
             selected_time: nil,
             available_slots: []
           } = updated.assigns
  end

  @tag :capture_log
  test "handle_timezone_change leaves the socket untouched for an unknown zone" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "UTC",
        selected_date: ~D[2024-01-01],
        selected_time: "10:00",
        timezone_dropdown_open: true
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Mars/Olympus")

    assert updated.assigns == socket.assigns
    refute_received {:fetch_available_slots, _date, _duration, _zone}
  end
end
