defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoadingZoneTest do
  @moduledoc """
  The grid's load window is the viewer's days in the viewer's zone, so a zone
  the profile changed since the grid last loaded is the one the next load uses.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading

  test "a reload after the profile's zone changed loads that zone's days" do
    user = insert(:user)
    profile = insert(:profile, user: user, timezone: "Asia/Tokyo")
    integration = insert(:calendar_integration, user: user, is_active: true)

    # 00:30 on Monday in Tokyo is 15:30 UTC on the Sunday before, a day the
    # week loaded in New York would not reach.
    start_at = ~U[2027-02-21 15:30:00Z]

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: start_at,
        end_at: DateTime.add(start_at, 30, :minute),
        all_day: false,
        recurrence_rule: nil,
        recurring_event_id: nil,
        sync_state: "synced"
      )

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_user: user,
        # The zone the grid loaded in before the profile changed.
        profile: profile,
        user_timezone: "America/New_York",
        preferences: %{week_start_day: "monday", show_weekends: true},
        integrations: [integration],
        events: [],
        hidden_integration_ids: [],
        view: :week,
        date: ~D[2027-02-24]
      }
    }

    socket = DataLoading.load_events(socket)

    assert socket.assigns.user_timezone == "Asia/Tokyo"
    assert Enum.any?(socket.assigns.events, &(&1.id == event.id))
  end
end
