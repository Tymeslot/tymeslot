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
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
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
        schedule: schedule,
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

      # Clear cache so any re-fetch is detectable
      AvailabilityCache.clear_all()

      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        "calendar_events:#{user.id}",
        {:calendar_events_updated, user.id, []}
      )

      # render/1 drains the LiveView message queue; assert the view still renders
      # and that availability was re-fetched (cache populated from sync fetch in test env)
      assert render(view) =~ "Quick Chat"
      assert :ets.info(:availability_cache, :size) > 0
    end

    @tag :capture_log
    test "handles :calendar_sync_complete without crashing", %{conn: conn} do
      {user, profile} = create_organiser()

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

      AvailabilityCache.clear_all()

      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        "calendar_events:#{user.id}",
        {:calendar_sync_complete, user.id, 1}
      )

      # Both PubSub messages trigger the same handler; verify availability was re-fetched
      assert render(view) =~ "Quick Chat"
      assert :ets.info(:availability_cache, :size) > 0
    end

    @tag :capture_log
    test "ignores calendar events for other users", %{conn: conn} do
      {_user, profile} = create_organiser()

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

      # Clear cache after initial mount fetch to isolate the broadcast's effect
      AvailabilityCache.clear_all()

      # Broadcast for a different user — should be a no-op
      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        "calendar_events:999999",
        {:calendar_events_updated, 999_999, []}
      )

      assert render(view) =~ "Quick Chat"
      # No re-fetch should have occurred for a different user's calendar topic
      assert :ets.info(:availability_cache, :size) == 0
    end
  end
end
