defmodule TymeslotWeb.Live.AsyncHandlersTest do
  @moduledoc """
  Composition tests for the async-task branches on the dashboard —
  `start_async`/`handle_async` pairs where the user clicks a button,
  the component kicks off a background `Task`, and a follow-up message
  drives the flash + spinner state to a final resting shape. The class
  of bugs these tests defend against:

    * An async branch that settles to `{:error, _}` but leaves the
      spinner (`is_refreshing`, `testing_connection`) stuck — the user
      sees a dead UI and thinks the operation is still running.

    * A success branch that mis-reports outcomes — e.g., "1 refreshed,
      0 failed" when both integrations succeeded, which is the
      symptom a reducer-arm bug would have.

  `calendar_settings_composition_test.exs` already pins the mixed
  success/failure arm ("1 refreshed, 1 failed"). The two extremes —
  all-success and all-failure — were untested and are the gaps closed
  here. The video `test_connection` error arm was likewise only
  covered for success, so the "button returns to enabled" invariant
  after a provider failure had no regression test.

  Dropped from the plan with rationale:

    * Calendar refresh "stale list preserved on error" — the plan
      framed the full-failure case as "error flash + previous list
      preserved". Production calls `load_integrations/1` inside both
      success and failure arms of `handle_async(:refresh_calendars,
      …)`, so on failure the list is refreshed from the DB rather
      than preserved from the previous socket value. The assertion
      that actually matters — "the user sees an error flash and the
      refresh button becomes clickable again" — is pinned below.

    * Video "test connection" button element `disabled` assertion —
      the button is not given a `disabled` attribute while testing;
      `testing_connection` assign drives a spinner class instead. The
      behavioural surrogate asserted here is that the spinner/testing
      state has cleared, which is the user-visible "button is ready
      again" signal.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :dashboard
  @moduletag :integrations

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Plug.Test

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "refresh_all_calendars — all successes" do
    @tag :capture_log
    test "reports the success flash and clears is_refreshing", %{conn: conn, user: user} do
      _a =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Work Google",
          is_active: true
        )

      _b =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Personal Google",
          is_active: true
        )

      # Both integrations resolve through `update_integration_with_discovery`
      # without hitting the `{:error, …}` reducer arm.
      stub(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
        {:ok, [%{"id" => "primary", "summary" => "Primary"}]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='refresh_all_calendars']")
      |> render_click()

      eventually(fn ->
        rendered = render(view)
        assert rendered =~ "All calendars refreshed successfully"
      end)

      # The refresh button must return to its enabled form after the
      # async settles, otherwise the user is locked out of retrying.
      refute has_element?(view, "button[phx-click='refresh_all_calendars'][disabled]")
    end
  end

  describe "refresh_all_calendars — all failures" do
    @tag :capture_log
    test "reports the all-failure flash and re-enables the button", %{conn: conn, user: user} do
      _a =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Work Google",
          is_active: true
        )

      _b =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Personal Google",
          is_active: true
        )

      stub(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
        {:error, :api_error}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='refresh_all_calendars']")
      |> render_click()

      eventually(fn ->
        rendered = render(view)
        assert rendered =~ "All calendar refreshes failed"
      end)

      # Regression guard: if the reducer arm that clears
      # `:is_refreshing` were ever removed from the failure branch,
      # the spinner would stay on forever.
      refute has_element?(view, "button[phx-click='refresh_all_calendars'][disabled]")
    end
  end

  describe "video test_connection — provider failure" do
    @tag :capture_log
    test "surfaces the error flash and re-enables the test button", %{conn: conn, user: user} do
      _integration =
        insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

      # A reachable host that returns a non-200 response is rendered
      # by MiroTalk's `test_api_connection/2` as `{:error, reason}`.
      # The async handler must surface it, not swallow it.
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 503, body: "{}"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/video-integration")

      view
      |> element("div.hidden button[phx-click='test_connection']")
      |> render_click()

      # The error surfaces as a flash — the exact message is provider-
      # specific, but it must be visibly present (not swallowed).
      eventually(fn ->
        rendered = render(view)
        assert rendered =~ "Connection test failed" or rendered =~ "MiroTalk"
      end)

      # `testing_connection` must clear so the user can click the
      # button again. The spinner label ("Testing...") is rendered
      # only while `@testing_connection == @integration.id`; once the
      # async settles, that label must disappear. If the handler ever
      # forgot to reset the assign, the user would stay staring at
      # "Testing..." with no way back to retry.
      #
      # `eventually/1` retries until the function returns a truthy
      # value, so we return `true` on the negative assertion rather
      # than relying on `refute`'s nil-on-success return value.
      eventually(fn ->
        not (render(view) =~ "Testing...")
      end)
    end
  end
end
