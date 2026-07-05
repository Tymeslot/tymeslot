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
    * `toggle_calendar_selection` happy path — clicking a calendar pill
      flips its `selected` flag in the persisted `calendar_list`. Pins
      the LiveComponent → `Calendar.toggle_calendar_selection/2` →
      Ecto-update seam that `dashboard_integrations_test.exs` used to
      cover with handle_event-only stubs.
    * `toggle_calendar_selection` race with deletion — if the underlying
      integration row is removed between mount and the click, the handler
      re-fetches by id, surfaces the not-found arm as a user-visible
      flash, and reloads the list so the stale entry disappears. Without
      the fresh fetch, `Repo.update` on the stale struct returns
      `{:ok, stale_struct}` (0 rows affected, no optimistic lock) and the
      user sees a silent no-op.
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
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :integrations
  @moduletag :calendar
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :verify_on_exit!

  setup do
    RateLimiter.clear_all()
    :ok
  end

  setup :setup_dashboard_user

  describe "setup prompt" do
    test "shows a prompt when no calendar is connected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      assert html =~ "You haven&#39;t connected a calendar yet"
    end

    test "hides the prompt once a calendar is connected", %{conn: conn, user: user} do
      insert(:calendar_integration, user: user, provider: "google", is_active: true)

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      refute html =~ "You haven&#39;t connected a calendar yet"
    end
  end

  describe "connect_provider navigation" do
    # Apple and Nextcloud show up-front; the remaining CalDAV presets stay
    # folded behind the "Other CalDAV server" card until revealed, so their
    # tests must expand the fold before the provider card is present.
    @always_shown_caldav_providers ~w(apple nextcloud)

    for {provider, label} <- [
          {"caldav", "CalDAV"},
          {"radicale", "Radicale"},
          {"nextcloud", "Nextcloud"},
          {"zimbra", "Zimbra"},
          {"mailbox_org", "mailbox.org"},
          {"apple", "Apple iCloud"},
          {"baikal", "Baikal"}
        ] do
      @provider provider
      @label label

      test "clicking #{label} provider card navigates to its config form", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

        if @provider not in @always_shown_caldav_providers do
          view
          |> element("button[phx-click='toggle_caldav_options']")
          |> render_click()
        end

        view
        |> element("button[phx-click='connect_provider'][phx-value-provider='#{@provider}']")
        |> render_click()

        assert render(view) =~ @label
      end
    end

    test "clicking Google Calendar initiates OAuth and redirects", %{conn: conn} do
      stub(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _user_id,
                                                                  _redirect_uri,
                                                                  _opts ->
        "https://accounts.google.com/o/oauth2/auth?fake=1"
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='connect_provider'][phx-value-provider='google']")
      |> render_click()

      assert_redirect(view, "https://accounts.google.com/o/oauth2/auth?fake=1")
    end

    test "clicking Outlook Calendar initiates OAuth and redirects", %{conn: conn} do
      stub(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn _user_id,
                                                                   _redirect_uri,
                                                                   _opts ->
        "https://login.microsoftonline.com/oauth?fake=1"
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='connect_provider'][phx-value-provider='outlook']")
      |> render_click()

      assert_redirect(view, "https://login.microsoftonline.com/oauth?fake=1")
    end
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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("#toggle-#{integration.id}")
      |> render_click()

      rendered = render(view)
      assert rendered =~ "Calendar status updated"
      refute Repo.get!(CalendarIntegrationSchema, integration.id).is_active
    end
  end

  describe "toggle_calendar_selection" do
    @tag :capture_log
    test "flipping a calendar pill persists the new selected flag", %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true,
          calendar_list: [
            %{
              "id" => "cal-primary",
              "path" => "cal-primary",
              "name" => "Primary",
              "type" => "calendar",
              "selected" => true
            }
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      # The chip grid lives in the connection row's expandable detail slot;
      # open it before clicking a calendar pill.
      view
      |> element("button[phx-click='toggle_row'][phx-value-id='#{integration.id}']")
      |> render_click()

      view
      |> element(
        "button[phx-click='toggle_calendar_selection']" <>
          "[phx-value-integration_id='#{integration.id}']" <>
          "[phx-value-calendar_id='cal-primary']"
      )
      |> render_click()

      [%{"id" => "cal-primary", "selected" => selected}] =
        Repo.get!(CalendarIntegrationSchema, integration.id).calendar_list

      refute selected
    end

    @tag :capture_log
    test "toggling a calendar after the integration was deleted flashes and refreshes the list",
         %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Soon-to-be-deleted",
          is_active: true,
          calendar_list: [
            %{
              "id" => "cal-primary",
              "path" => "cal-primary",
              "name" => "Primary",
              "type" => "calendar",
              "selected" => true
            }
          ]
        )

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      assert html =~ "Soon-to-be-deleted"

      # Expand the row (client-side state only) so the calendar pill is in
      # the DOM before we simulate the deletion race.
      view
      |> element("button[phx-click='toggle_row'][phx-value-id='#{integration.id}']")
      |> render_click()

      # Simulate the user deleting the integration from another tab
      # between page load and click. Without the pre-update existence
      # check, `Repo.update` on the stale struct would succeed silently
      # (0 rows affected, no optimistic lock) and the user would see
      # no feedback at all.
      Repo.delete!(integration)

      view
      |> element(
        "button[phx-click='toggle_calendar_selection']" <>
          "[phx-value-integration_id='#{integration.id}']" <>
          "[phx-value-calendar_id='cal-primary']"
      )
      |> render_click()

      rendered = render(view)
      assert rendered =~ "This calendar integration is no longer available."
      refute rendered =~ "Soon-to-be-deleted"
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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      # The delete control lives in the connection row's expandable actions
      # slot; open the row before reaching for it.
      view
      |> element("button[phx-click='toggle_row'][phx-value-id='#{primary.id}']")
      |> render_click()

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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='toggle_row'][phx-value-id='#{integration.id}']")
      |> render_click()

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

  describe "free/busy feed" do
    test "enable_freebusy generates a token, renders the feed URL, and persists it", %{
      conn: conn,
      user: user
    } do
      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      refute html =~ "/free-busy/"

      view
      |> element("button[phx-click='enable_freebusy']")
      |> render_click()

      rendered = render(view)
      assert rendered =~ "/free-busy/"

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert is_binary(profile.freebusy_token) and profile.freebusy_token != ""
      assert rendered =~ profile.freebusy_token
    end

    test "regenerate_freebusy replaces the token and renders the new URL", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='enable_freebusy']")
      |> render_click()

      {:ok, after_enable} = ProfileQueries.get_by_user_id(user.id)
      first_token = after_enable.freebusy_token

      view
      |> element("button[phx-click='regenerate_freebusy']")
      |> render_click()

      {:ok, after_regen} = ProfileQueries.get_by_user_id(user.id)
      assert after_regen.freebusy_token != first_token

      rendered = render(view)
      assert rendered =~ "/free-busy/"
      assert rendered =~ after_regen.freebusy_token
      refute rendered =~ first_token
    end

    test "disable_freebusy clears the token and hides the feed URL", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='enable_freebusy']")
      |> render_click()

      assert render(view) =~ "/free-busy/"

      view
      |> element("button[phx-click='disable_freebusy']")
      |> render_click()

      rendered = render(view)
      refute rendered =~ "/free-busy/"
      assert has_element?(view, "button[phx-click='enable_freebusy']")

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert is_nil(profile.freebusy_token)
    end
  end
end
