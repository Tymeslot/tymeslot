defmodule TymeslotWeb.OnboardingCompositionTest do
  @moduledoc """
  Composition tests for the onboarding LiveView that complement the
  existing five-file coverage suite:

    * `onboarding_navigation_test.exs` — forward/backward navigation,
      skip modal + `skip_onboarding` redirect, progress indicators.
    * `onboarding_validation_test.exs` — form-level validation,
      duplicate-username rejection, available-username happy path.
    * `onboarding_edge_cases_test.exs` — scheduling boundary rejection
      (negative and oversized buffer_minutes), preset-spoofing guard.
    * `onboarding_custom_inputs_test.exs` — custom-input mode
      transitions across scheduling preferences.
    * `onboarding_live_test.exs` — mount, step parameterisation,
      timezone prefill from connect params.

  This file pins the two composition seams that are genuinely
  uncovered:

    * skip → `previous_step` round trip — the user selects "Not right
      now" on connect_calendar, presses Continue, immediately changes
      their mind, and hits Back. The combination is never exercised;
      each handler is tested in isolation.
    * connected calendar row — a user with an already-connected
      calendar sees it rendered as a read-only "connected" row, and an
      existing connection enables Continue without a fresh provider
      selection.

  It also tightens the `skip_onboarding` coverage by asserting the
  `ensure_username` auto-assignment side effect, which the existing
  navigation test leaves unchecked (it only asserts the redirect and
  `onboarding_completed_at`).

  Dropped from the plan with rationale:

    * `previous_step` from each step rebuilds form data; from
      `:welcome` is no-op — covered by
      `onboarding_navigation_test.exs:147` ("backward navigation
      preserves filled form data") and `:174` ("no previous button
      on welcome step"). Duplicating here would be Credo-flavour.
    * `update_basic_settings` with duplicate username — covered end
      to end at `onboarding_validation_test.exs:202` ("taken username
      shows error") with the `"already taken"` flash assertion.
    * `update_scheduling_preferences` with negative values —
      covered at `onboarding_edge_cases_test.exs:40` ("negative
      buffer_minutes value is rejected").
    * CalDAV form → `validate_caldav` →
      `discover_caldav_calendars` with network timeout — the CalDAV
      discovery chain is already pinned at the domain level by
      Task 28 in `test/remaining-gaps`
      (`caldav_discovery_chain_test.exs`). The onboarding LiveView
      adds only a single-assign wrapper around
      `Calendar.discover_and_filter_calendars/4`; mocking the CalDAV
      HTTP round-trip through the onboarding view adds complexity
      without new seam coverage.
    * `discover_caldav_calendars` with 0 calendars → "no calendars
      found" state — the premise is contradicted by the production
      code. `calendar_handlers.ex:158` unconditionally calls
      `create_integration_with_validation` on any `{:ok, %{calendars:
      _}}` response regardless of list emptiness; there is no
      "no calendars found" branch to assert against.
    * `change_timezone` with invalid string → validation error,
      dropdown stays open — the plan's "dropdown stays open" claim
      is contradicted by the production code.
      `timezone_handlers.ex:54–56` unconditionally assigns
      `timezone_dropdown_open: false` before validation, so the
      dropdown always closes. The remaining behaviour (error set in
      `form_errors`) is a defensive guard for a state the UI cannot
      emit — every rendered option is a valid timezone from
      `Timezones.all_options()`, and `phx-value-timezone` only carries
      server-sourced values.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :onboarding
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Profiles

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "skip_step → previous_step round trip" do
    test "skipping connect_calendar then stepping back returns to connect_calendar",
         %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # welcome → profile
      view |> element("button[phx-click='next_step']") |> render_click()

      fill_basic_settings(
        view,
        "Round Trip User",
        "roundtripuser#{System.unique_integer([:positive])}"
      )

      # profile → connect_calendar
      view |> element("button[phx-click='next_step']") |> render_click()
      assert has_element?(view, ".onboarding-provider-cards")

      # connect_calendar → select skip → Continue → confirm nudge → buffer_time
      view |> element(~s{button[phx-value-option="skip"]}) |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()
      render_click(view, "confirm_skip_calendar")
      assert has_element?(view, "button[phx-value-buffer_minutes]")

      # buffer_time → previous → connect_calendar
      view |> element("button[phx-click='previous_step']") |> render_click()

      # The provider grid must be visible again — the user's "I
      # changed my mind" path has to land them back where they
      # skipped from, not somewhere further forward or at the form
      # they were editing.
      assert has_element?(view, ".onboarding-provider-cards")
    end
  end

  describe "skip_onboarding with a blank username" do
    test "auto-assigns a default username via ensure_username",
         %{conn: conn} do
      # setup_onboarding creates a user but no profile — the mount
      # calls get_or_create_profile which inserts a blank-username
      # profile, exactly the "user skipped straight from welcome"
      # shape.
      {:ok, view, _html, user} = setup_onboarding(conn)

      render_click(view, "show_skip_modal")
      render_click(view, "skip_onboarding")

      assert_redirect(view, ~p"/dashboard")

      # User.onboarding_completed_at is already covered in
      # onboarding_navigation_test; here the novel assertion is that
      # the profile received a generated username so the user's
      # booking page is reachable on first dashboard visit.
      {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
      assert profile.username =~ ~r/\A[a-z0-9][a-z0-9_-]*\z/
    end
  end

  describe "connected calendar row" do
    test "renders connected calendars read-only and enables Continue",
         %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)

      existing_calendar =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          provider_account_email: "work@example.com",
          name: "Existing Work Calendar"
        )

      # Skip the fixture helper because we need a pre-existing
      # integration — setup_onboarding inserts none by default.
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/onboarding?step=connect_calendar")

      html = render(view)

      # The connected calendar renders as a read-only row, not a button.
      assert has_element?(view, "div.onboarding-connected-calendar")
      assert html =~ "work@example.com"
      assert html =~ "Caldav · Connected"

      # An existing connection enables Continue (it is not disabled), even
      # without selecting a provider choice.
      refute has_element?(view, "button[phx-click='next_step'][disabled]")

      # The "Not right now" choice is hidden once a calendar is connected;
      # the user can still add more by selecting another provider's card.
      refute has_element?(view, ~s{button[phx-value-option="skip"]})

      # The connected calendar still exists in the DB.
      assert {:ok, _refreshed} = Calendar.get_integration(existing_calendar.id, user.id)
      assert length(Calendar.list_integrations(user.id)) == 1
    end
  end
end
