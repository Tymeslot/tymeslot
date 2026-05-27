defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.VisibilityTest do
  @moduledoc """
  Unit tests for Visibility — the calendar-grid refresh and calendar-list
  toggle handlers.

  These bypass the LiveComponent harness and drive the handlers directly
  against a synthetic socket, mirroring the pattern in `PreferencesTest`.

  `Flash.put_flash/3` sends `{:flash, {type, msg}}` to the calling process
  rather than mutating the socket, so we assert on `assert_receive` rather
  than socket assigns for flash outcomes.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory

  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Visibility

  defp build_socket(user) do
    profile = insert(:profile, user: user, timezone: "Europe/Berlin")
    integration = insert(:calendar_integration, user: user)

    preferences = %{
      week_start_day: "monday",
      time_format: "24h",
      default_view: "week",
      show_week_numbers: false,
      show_weekends: true
    }

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        profile: profile,
        preferences: preferences,
        integrations: [integration],
        events: [],
        hidden_integration_ids: [],
        visible_events: [],
        visible_days: [],
        view: :week,
        date: ~D[2026-04-14],
        syncing: false,
        sync_total: 0,
        sync_completed: 0,
        show_settings: false,
        show_calendar_list: false,
        show_view_menu: false,
        stale_integrations: [],
        oldest_sync_at: nil,
        owned_integration_ids: MapSet.new(),
        video_integrations: []
      }
    }
  end

  describe "handle_refresh/2 — rate-limited path" do
    test "puts a warning flash and leaves the socket unchanged when rate limit is exceeded" do
      user = insert(:user)
      socket = build_socket(user)

      # Exhaust the 10-per-600s bucket for this user.
      for _i <- 1..10 do
        RateLimiter.check_calendar_refresh_rate_limit(user.id)
      end

      on_exit(fn -> RateLimiter.clear_bucket("calendar_refresh:#{user.id}") end)

      {:noreply, returned_socket} = Visibility.handle_refresh(%{}, socket)

      assert_receive {:flash, {:warning, "Too many refreshes. Please wait a moment."}}
      # Socket assigns must be untouched (syncing remains false).
      assert returned_socket.assigns.syncing == false
    end
  end

  describe "handle_refresh/2 — success path" do
    test "loads events and returns an updated socket when within rate limit" do
      user = insert(:user)
      socket = build_socket(user)

      on_exit(fn -> RateLimiter.clear_bucket("calendar_refresh:#{user.id}") end)

      {:noreply, returned_socket} = Visibility.handle_refresh(%{}, socket)

      # The socket should be alive — we don't assert a specific flash message
      # because the outcome depends on what workers were enqueued, but the
      # handler must not crash and must return a valid socket.
      assert %Phoenix.LiveView.Socket{} = returned_socket
    end
  end
end
