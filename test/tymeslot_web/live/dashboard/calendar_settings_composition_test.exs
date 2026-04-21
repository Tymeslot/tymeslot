defmodule TymeslotWeb.Dashboard.CalendarSettingsCompositionTest do
  @moduledoc """
  Composition tests for `TymeslotWeb.Dashboard.CalendarSettingsComponent` —
  the dashboard UI where users refresh, toggle, and delete calendar
  integrations. Existing tests cover only rate-limit paths; the
  interactive lifecycle events and their async/DB coupling were untested
  end-to-end.

  Covered scenarios (plan lines 1826–1833):

    * `refresh_all_calendars` with a mixed success/failure result — the
      flash reports accurate counts and `is_refreshing` clears so the
      button becomes clickable again even after a partial failure.
    * `toggle_integration` full round-trip — the DB `is_active` flag
      flips and the view refreshes; pins the LiveComponent → Calendar
      context → Ecto-update seam that has no composition coverage today.
    * Delete modal → confirm on the **primary** integration with another
      active one present — the secondary is promoted to primary on the
      profile. Pins the LiveComponent → Deletion → ProfileQueries chain.
    * Delete modal → confirm on the only integration — primary is
      cleared on the profile. A dangling FK here would crash the next
      profile load.

  Dropped from the plan with rationale:

    * Full Nextcloud discover → select → submit → persist flow and the
      related 503 / timeout / empty-list scenarios require raw CalDAV
      XML mocking infrastructure that does not exist in this repo; each
      would need several hundred lines of multistatus fixture setup and
      would reassert behaviour already covered by the CalDAV discovery
      tests under `tymeslot/integrations/calendar/caldav/`.
    * `SanitizeMerge` empty-string URL regression — `SanitizeMerge.merge/2`
      preserves `""` by design (sanitisers use the empty string to wipe
      malicious values). Existing unit tests in `sanitize_merge_test.exs`
      pin this; reaching it through the LiveComponent would need the
      same XML mocking as above.
    * Cross-user IDOR on `toggle_integration` — already covered at the
      domain layer in `calendar_test.exs:48` and `deletion_test.exs:112`.
      Re-testing through the LiveComponent adds nothing because
      `load_integrations/1` pre-filters by `user_id` and the toggle
      button never renders for integrations the current user does not
      own.
    * `test_connection` against a timed-out integration — no UI button
      in `calendar_settings/components.ex` emits the `test_connection`
      event today. The handler at `calendar_settings_component.ex:315`
      is currently unreachable through the UI, so a composition test
      would only exercise the handler directly, which is a unit test.
    * `toggle_calendar_selection` for an integration deleted mid-session
      — uncovered a separate bug: the handler passes the stale struct
      from socket assigns into `Calendar.toggle_calendar_selection/2`,
      which raises `Ecto.StaleEntryError` instead of returning an error
      tuple. The component never sees `{:error, _}`, so the user gets
      a LiveView crash rather than the "Failed to update selection"
      flash the component's `else` branch promises. Landing the
      regression test here would require the production fix; per the
      plan's test-only worktree policy, this goes as a follow-up in a
      dedicated fix worktree.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :integrations
  @moduletag :calendar
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :verify_on_exit!

  setup %{conn: conn} do
    RateLimiter.clear_all()

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)

    %{conn: conn, user: user, profile: profile}
  end

  describe "refresh_all_calendars" do
    @tag :capture_log
    test "partial failure across integrations surfaces accurate counts and clears is_refreshing",
         %{conn: conn, user: user} do
      ok_integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Work Google",
          is_active: true
        )

      fail_integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Personal Google",
          is_active: true
        )

      # Route each integration through the mock to a different outcome.
      # The discovery pipeline threads the full integration struct into
      # the API call, so we key on `:id` to split success from failure
      # while keeping the mocks at the external boundary.
      stub(GoogleCalendarAPIMock, :list_calendars, fn %{id: id} ->
        if id == ok_integration.id do
          {:ok, [%{"id" => "primary", "summary" => "Primary"}]}
        else
          {:error, :api_error}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='refresh_all_calendars']")
      |> render_click()

      eventually(fn ->
        rendered = render(view)
        assert rendered =~ "1 refreshed, 1 failed"
        assert rendered =~ fail_integration.name
      end)

      # The button must become clickable again once the async settle
      # runs through `handle_async(:refresh_calendars, ...)`. If
      # `is_refreshing` stayed true, the user would see "Refreshing..."
      # forever on any transient failure.
      refute has_element?(view, "button[phx-click='refresh_all_calendars'][disabled]")
    end
  end

  describe "toggle_integration" do
    @tag :capture_log
    test "flipping a connected integration's status persists to the DB", %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("#calendar-toggle-#{integration.id}")
      |> render_click()

      rendered = render(view)
      assert rendered =~ "Calendar status updated"
      refute Repo.get!(CalendarIntegrationSchema, integration.id).is_active
    end
  end

  describe "delete_with_primary_reassignment (modal → confirm)" do
    @tag :capture_log
    test "deleting the primary integration promotes another active integration", %{
      conn: conn,
      user: user
    } do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Primary Google",
          is_active: true
        )

      secondary =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Secondary Google",
          is_active: true
        )

      {:ok, _profile} = CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      # Open the delete modal for the primary integration. The click
      # pushes a `show` event at the dedicated modal component.
      view
      |> element(
        "button[phx-click='show'][phx-value-id='#{primary.id}'][phx-target='#delete-calendar-modal']"
      )
      |> render_click()

      # Confirm inside the modal. The confirm button uses a `JS.push`
      # that renders as an encoded command, so we select it by its
      # visible label instead of by phx-click text.
      view
      |> element("#delete-calendar-modal button", "Delete Integration")
      |> render_click()

      assert render(view) =~ "Integration deleted successfully"
      assert Repo.get(CalendarIntegrationSchema, primary.id) == nil

      # The profile's pointer must have been promoted to the only
      # remaining active integration. Without this, meeting creation
      # that reads the primary would hit `:no_primary_calendar` for a
      # user who still has a calendar connected — the symptom the
      # Deletion.promote_next_or_clear/2 code path exists to prevent.
      {:ok, fresh_profile} = ProfileQueries.get_by_user_id(user.id)
      assert fresh_profile.primary_calendar_integration_id == secondary.id
    end

    @tag :capture_log
    test "deleting the only integration clears primary on the profile", %{
      conn: conn,
      user: user
    } do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Only Google",
          is_active: true
        )

      {:ok, _profile} = CalendarPrimary.set_primary_calendar_integration(user.id, integration.id)

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element(
        "button[phx-click='show'][phx-value-id='#{integration.id}'][phx-target='#delete-calendar-modal']"
      )
      |> render_click()

      view
      |> element("#delete-calendar-modal button", "Delete Integration")
      |> render_click()

      assert render(view) =~ "Integration deleted successfully"
      assert Repo.get(CalendarIntegrationSchema, integration.id) == nil

      # If `primary_calendar_integration_id` stayed set to the deleted
      # id, the FK reference would leak past clear_primary; subsequent
      # profile reads that preload the primary integration would crash.
      {:ok, fresh_profile} = ProfileQueries.get_by_user_id(user.id)
      assert fresh_profile.primary_calendar_integration_id == nil
    end
  end
end
