defmodule TymeslotWeb.Themes.Shared.Journey.AmbientTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Test.ClockHelpers
  alias TymeslotWeb.Themes.Shared.Journey.Ambient

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  test "are the timezone picker's four events" do
    assert Ambient.events() == [
             :change_timezone,
             :search_timezone,
             :toggle_timezone_dropdown,
             :close_timezone_dropdown
           ]
  end

  test "toggling the picker opens a closed one and closes an open one" do
    assert {:noreply, socket} =
             Ambient.handle(
               socket(%{timezone_dropdown_open: false}),
               :toggle_timezone_dropdown,
               nil
             )

    assert socket.assigns.timezone_dropdown_open

    assert {:noreply, socket} = Ambient.handle(socket, :toggle_timezone_dropdown, nil)
    refute socket.assigns.timezone_dropdown_open
  end

  test "closing the picker waits a moment, so a click inside it still lands" do
    socket = socket(%{timezone_dropdown_open: true})

    assert {:noreply, ^socket} = Ambient.handle(socket, :close_timezone_dropdown, nil)
    assert_receive :close_dropdown, 1_000
  end

  test "picking a timezone moves a calendar the booker has not touched to that zone's today" do
    ClockHelpers.freeze_clock(~U[2027-01-31 12:00:00Z])

    socket =
      socket(%{
        user_timezone: "Europe/Tallinn",
        week_start: :monday,
        calendar_today: ~D[2027-01-31],
        current_year: 2027,
        current_month: 1,
        current_week_start: ~D[2027-01-25],
        calendar_landing: %{
          selected_date: nil,
          current_year: 2027,
          current_month: 1,
          current_week_start: ~D[2027-01-25]
        },
        selected_date: nil,
        selected_time: nil,
        available_slots: [],
        timezone_dropdown_open: true,
        timezone_search: ""
      })

    assert {:noreply, socket} = Ambient.handle(socket, :change_timezone, "Pacific/Kiritimati")

    assert %{
             user_timezone: "Pacific/Kiritimati",
             calendar_today: ~D[2027-02-01],
             current_year: 2027,
             current_month: 2,
             current_week_start: ~D[2027-02-01]
           } = socket.assigns
  end
end
