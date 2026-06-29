defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.NavigationTest do
  @moduledoc """
  Unit tests for the calendar-grid navigation handlers. Covers the month-view
  click-through (REQ-023): clicking a day cell in the month grid dispatches
  `navigate_to_day`, which jumps the grid to the day view for that date and
  closes the mini-month popover.

  These drive the handler directly against a synthetic socket, mirroring the
  pattern in `PreferencesTest` and `VisibilityTest`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Navigation

  defp build_socket(user) do
    profile = insert(:profile, user: user, timezone: "Europe/Berlin")

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_user: user,
        profile: profile,
        integrations: [],
        events: [],
        hidden_integration_ids: [],
        view: :month,
        date: ~D[2026-04-15],
        mini_month_open: true,
        mini_month_cursor: ~D[2026-04-01]
      }
    }
  end

  describe "handle_navigate_to_day/2" do
    test "switches to the day view for the picked date and closes the mini-month" do
      user = insert(:user)
      socket = build_socket(user)

      {:noreply, updated} =
        Navigation.handle_navigate_to_day(%{"date" => "2026-04-09"}, socket)

      assert updated.assigns.view == :day
      assert updated.assigns.date == ~D[2026-04-09]
      assert updated.assigns.mini_month_open == false
      assert updated.assigns.mini_month_cursor == nil
    end

    test "is a no-op for an unparseable date string" do
      user = insert(:user)
      socket = build_socket(user)

      assert {:noreply, ^socket} =
               Navigation.handle_navigate_to_day(%{"date" => "not-a-date"}, socket)
    end
  end
end
