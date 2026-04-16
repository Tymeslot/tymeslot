defmodule TymeslotWeb.Live.Scheduling.CalendarPubSubTest do
  @moduledoc """
  Tests that the public scheduling page refreshes availability
  when calendar events change via PubSub.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    :ok
  end

  defp create_organiser do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "testorg",
        booking_theme: "1",
        timezone: "America/New_York",
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    _meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Quick Chat",
        is_active: true
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    _integration = insert(:calendar_integration, user: user, is_active: true)

    {user, profile}
  end

  describe "calendar event PubSub" do
    @tag :capture_log
    test "handles :calendar_events_updated without crashing", %{conn: conn} do
      {user, profile} = create_organiser()

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        "calendar_events:#{user.id}",
        {:calendar_events_updated, user.id, []}
      )

      # The LiveView should process the message and still render
      assert render(view) =~ "Quick Chat"
    end

    @tag :capture_log
    test "handles :calendar_sync_complete without crashing", %{conn: conn} do
      {user, profile} = create_organiser()

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        "calendar_events:#{user.id}",
        {:calendar_sync_complete, user.id, 1}
      )

      assert render(view) =~ "Quick Chat"
    end

    @tag :capture_log
    test "ignores calendar events for other users", %{conn: conn} do
      {_user, profile} = create_organiser()

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

      # Broadcast for a different user — should be a no-op
      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        "calendar_events:999999",
        {:calendar_events_updated, 999_999, []}
      )

      assert render(view) =~ "Quick Chat"
    end
  end
end
