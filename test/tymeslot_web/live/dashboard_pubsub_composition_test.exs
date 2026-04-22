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
  seam:

    1. The user mounts the dashboard with a live calendar integration.
    2. The user opens the Add Meeting Type form and clicks the
       integration button — this sets `refreshing_calendars: true` in
       the form component and sends `{:refresh_calendar_list, ...}` to
       the parent LiveView, which spawns the async task.
    3. Before the async task completes, the integration is deleted
       (another tab, admin revocation).
    4. The async task finds `{:error, :not_found}` and sends back
       `{:calendar_list_refreshed, form_id, integration_id, []}`.
    5. The parent's `handle_info` must forward the update to the form
       component, clearing the spinner — not crash or leave it stuck.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :meetings
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Integrations.Calendar

  setup_all do
    case Process.whereis(DashboardCache) do
      nil -> start_supervised!(DashboardCache)
      _pid -> :ok
    end

    :ok
  end

  setup :setup_dashboard_user

  setup do
    DashboardCache.clear_all()
    :ok
  end

  describe "refresh_calendar_list — integration deleted mid-flight" do
    @tag :capture_log
    test "spinner clears after the async task returns not-found for a deleted integration",
         %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, provider: "google")

      # Mount with the integration present so the calendar picker renders.
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      # Open the Add Meeting Type form so MeetingTypeForm mounts with
      # id "meeting-type-form-new".
      view |> element("button", "Add Meeting Type") |> render_click()

      # Simulate the race: delete the integration before the user's
      # click is processed. The component's assigns are not reloaded by
      # the deletion (no PubSub broadcast), so the integration button
      # remains in the rendered HTML. When the click fires the async
      # task, `CalendarManagement.get_calendar_integration/2` will
      # return `{:error, :not_found}`.
      {:ok, _deleted} = Calendar.delete_integration(integration.id, user.id)

      # Click the calendar integration button — the real UI path for
      # `select_calendar_integration`. This sets
      # `refreshing_calendars: true` and `selected_calendar_integration_id`
      # in the form component, then queues
      # `{:refresh_calendar_list, form_id, integration.id}` to the parent
      # LiveView which spawns the async task. The task finds
      # `{:error, :not_found}` (integration deleted above) and sends back
      # `{:calendar_list_refreshed, form_id, integration.id, []}`.
      view
      |> element(
        "button[phx-click*='select_calendar_integration'][phx-click*='#{integration.id}']"
      )
      |> render_click()

      # Sharp seam assertion: the empty-calendar-list branch only renders
      # after `handle_info({:calendar_list_refreshed, ...})` runs
      # `send_update(MeetingTypeForm, refreshing_calendars: false,
      # calendars: [])`. If either `handle_info` clause raised, LiveView
      # would rescue but `send_update` would never fire — the component
      # would stay on `refreshing_calendars: true` and this text would
      # never render. (The outer `:if @selected_calendar_integration_id`
      # gate is satisfied by the click setting that assign alongside the
      # spinner.)
      wait_until(fn ->
        assert render(view) =~ "No calendars found for this account."
      end)
    end
  end
end
