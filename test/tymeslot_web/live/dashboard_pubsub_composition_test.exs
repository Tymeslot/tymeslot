defmodule TymeslotWeb.DashboardPubsubCompositionTest do
  @moduledoc """
  Composition tests for `DashboardLive.handle_info/2` PubSub seams.

  Most `handle_info` clauses in `DashboardLive` are thin `send_update`
  shims that are already exercised end-to-end by the send-side tests
  (calendar integration add/delete, telegram link, profile update).
  This file pins the one path that has a real failure mode the user
  sees: the async calendar-refresh round trip when the integration has
  been deleted between the user's click and the spawned task's
  `get_calendar_integration` call.

  The failure mode we're guarding against: if the handle_info for
  `:refresh_calendar_list` (or its sibling `:calendar_list_refreshed`)
  crashed on a stale integration id, the meeting-type form would be
  left with `refreshing_calendars: true` forever — a stuck spinner the
  user can only clear by reloading the page.

  The existing `workflows_test.exs` pins the workflow-level behaviour
  (the async task sends an empty-list `:calendar_list_refreshed`
  message when `CalendarManagement.get_calendar_integration/2` returns
  `{:error, :not_found}`). This test pins the LiveView side of that
  seam: the dashboard must survive receiving both messages and keep
  rendering.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :meetings
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test, as: PlugTest
  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Integrations.Calendar

  setup_all do
    case Process.whereis(DashboardCache) do
      nil -> start_supervised!(DashboardCache)
      _pid -> :ok
    end

    :ok
  end

  setup %{conn: conn} do
    DashboardCache.clear_all()

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "pubsubuser", full_name: "PubSub User")

    conn =
      conn
      |> PlugTest.init_test_session(%{})
      |> log_in_user(user)

    {:ok, conn: conn, user: user}
  end

  describe "refresh_calendar_list — integration deleted mid-flight" do
    @tag :capture_log
    test "handles a refresh request for an already-deleted integration without crashing the LiveView",
         %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, provider: "google")

      # Simulate the race: the user clicked "select calendar" and the
      # refresh message is in flight, but the integration has been
      # deleted in another tab (or by an admin revocation) before the
      # async task fires.
      {:ok, _deleted} = Calendar.delete_integration(integration.id, user.id)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      # Feed the handler directly — the real UI path is
      # `select_calendar_integration` inside the meeting-type form, but
      # the handler under test is on the parent DashboardLive and does
      # not care which form emitted the message. The form id below is
      # intentionally fictitious to mimic a component that has since
      # unmounted.
      send(view.pid, {:refresh_calendar_list, "ghost-form", integration.id})

      # The async task sends :calendar_list_refreshed back to the
      # LiveView. Wait for both hops to settle.
      wait_until(fn ->
        assert Process.alive?(view.pid)
        # A subsequent render must succeed — if either handle_info
        # raised, the LiveView would be down and this would error.
        assert render(view) =~ "Meeting Settings"
      end)
    end
  end
end
