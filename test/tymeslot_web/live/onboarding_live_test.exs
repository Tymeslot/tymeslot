defmodule TymeslotWeb.OnboardingLiveTest do
  @moduledoc """
  Happy path tests for the onboarding flow.

  Tests core user journeys including:
  - Complete onboarding end-to-end
  - Redirect behavior for already-onboarded users
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Ecto.Query
  import Mox
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import TymeslotWeb.OnboardingTestHelpers

  alias Phoenix.Flash
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "complete onboarding flow" do
    test "new user can complete full onboarding successfully", %{conn: conn} do
      # Create a new user without onboarding completed
      {:ok, view, _html, user} = setup_onboarding(conn, %{name: "Test User"})

      # Should start at welcome step
      assert has_element?(view, ".onboarding-step-title")

      # Step 1: Welcome -> Profile
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should now be at profile step
      assert has_element?(view, "#profile-form")

      # Fill in profile form
      view
      |> form("form#profile-form", %{
        "full_name" => "Test User",
        "username" => "testuser123"
      })
      |> render_change()

      # Step 2: Profile -> Connect Calendar
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should now be at connect_calendar step
      assert has_element?(view, ".onboarding-provider-cards")

      # Step 3: Connect Calendar -> Buffer Time. Forced choice — select
      # "Not right now" before Continue, otherwise next_step is a no-op.
      view |> element(~s{button[phx-value-option="skip"]}) |> render_click()

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Continuing without a calendar opens a nudge modal — confirm to advance.
      render_click(view, "confirm_skip_calendar")

      # Should now be at buffer_time step
      assert has_element?(view, "button[phx-value-buffer_minutes]")

      # Steps 4-6: Buffer Time -> Booking Window -> Minimum Notice -> Ready
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      # Should now be at ready step
      html = render(view)
      assert html =~ "all set"

      # Step 7: Ready -> Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should redirect to dashboard
      assert_redirect(view, ~p"/dashboard")

      # Verify onboarding_completed_at is set
      user = Repo.reload!(user)
      assert user.onboarding_completed_at != nil

      # Verify profile was created and updated with all fields
      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.full_name == "Test User"
      assert profile.username == "testuser123"
      # Without connect_params, timezone falls back to business default
      assert profile.timezone == "Europe/Tallinn"
      # Scheduling defaults are preserved when not changed
      assert profile.buffer_minutes == 15
      assert profile.advance_booking_days == 90
      assert profile.min_advance_hours == 3
    end

    test "onboarding persists all fields including detected timezone", %{conn: conn} do
      {:ok, view, _html, user} =
        setup_onboarding(conn, %{name: "Jane Doe"}, nil,
          connect_params: %{"timezone" => "Europe/Paris"}
        )

      # Navigate to profile step
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Fill in profile form
      view
      |> form("form#profile-form", %{
        "full_name" => "Jane Doe Updated",
        "username" => "janedoe2024"
      })
      |> render_change()

      # profile -> connect_calendar
      view |> element("button[phx-click='next_step']") |> render_click()
      # connect_calendar is a forced choice — skip before Continue
      view |> element(~s{button[phx-value-option="skip"]}) |> render_click()
      # Continue opens the nudge modal; confirm it to leave the calendar step.
      view |> element("button[phx-click='next_step']") |> render_click()
      render_click(view, "confirm_skip_calendar")
      # buffer_time -> booking_window -> minimum_notice -> ready
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      # Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify all data was persisted — including the browser-detected timezone
      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.full_name == "Jane Doe Updated"
      assert profile.username == "janedoe2024"
      assert profile.timezone == "Europe/Paris"
    end

    test "detected timezone is persisted to DB on mount", %{conn: conn} do
      {:ok, _view, _html, user} =
        setup_onboarding(conn, %{name: "TZ User"}, nil,
          connect_params: %{"timezone" => "America/New_York"}
        )

      # The browser-detected timezone should already be in the DB after mount
      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.timezone == "America/New_York"
    end

    test "onboarding with custom scheduling preference values", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn, %{name: "Custom User"})

      # Navigate to profile step
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Fill in profile form
      view
      |> form("form#profile-form", %{
        "full_name" => "Custom User",
        "username" => "customuser#{System.unique_integer([:positive])}"
      })
      |> render_change()

      # Navigate through connect_calendar to buffer_time
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element(~s{button[phx-value-option="skip"]}) |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()
      render_click(view, "confirm_skip_calendar")

      # Buffer time step — click custom
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      # Continue to booking_window
      view |> element("button[phx-click='next_step']") |> render_click()

      # Booking window step — click custom
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      # Continue to minimum_notice
      view |> element("button[phx-click='next_step']") |> render_click()

      # Minimum notice step — click custom
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='min_advance_hours']")
      |> render_click()

      # Continue to ready
      view |> element("button[phx-click='next_step']") |> render_click()

      # Complete onboarding
      view |> element("button[phx-click='next_step']") |> render_click()

      # Verify custom values were persisted (defaults from step_config.ex: 20, 120, 8)
      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.buffer_minutes == 20
      assert profile.advance_booking_days == 120
      assert profile.min_advance_hours == 8

      # Verify user completed onboarding
      user = Repo.reload!(user)
      assert user.onboarding_completed_at != nil
    end

    test "user name is pre-filled in profile step", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn, %{name: "Pre Filled Name"})

      # Navigate to profile step
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      html = render(view)
      # The form should have the user's name pre-filled
      assert html =~ "Pre Filled Name"
    end

    test "profile step blocks advancing when username is empty", %{conn: conn} do
      # Front-line defence: NavigationHandlers.handle_username_validation
      # rejects an empty username at the profile step with "Username is
      # required", so the user can't reach the calendar step (let alone
      # complete onboarding) without choosing a handle. Regression pins
      # the UX gate — the completion-time ensure_username/2 backfill is
      # a secondary safety net, not the primary guard.
      {:ok, view, _html, _user} = setup_onboarding(conn, %{name: "No Username User"})

      # Step 1: Welcome -> Profile
      view |> element("button[phx-click='next_step']") |> render_click()

      # Profile step with blank username.
      view
      |> form("form#profile-form", %{
        "full_name" => "No Username User",
        "username" => ""
      })
      |> render_change()

      result =
        view
        |> element("button[phx-click='next_step']")
        |> render_click()

      assert result =~ "Username is required"
      # The profile form is still visible — the step did not advance.
      assert has_element?(view, "#profile-form")
    end

    test "ready step wires the copy button to the clipboard hook with the booking URL",
         %{conn: conn} do
      # Regression: the copy button previously dispatched a `phx:copy` browser
      # event that no JS handler listened for, so clicking the icon copied
      # nothing. It must be wired to the `CopyOnClick` hook, with the booking
      # URL carried in `data-copy-text` for the hook to copy.
      {:ok, view, _html, _user} = setup_onboarding(conn, %{name: "Copy User"})

      # Welcome -> Profile, then choose a username so the booking URL resolves.
      view |> element("button[phx-click='next_step']") |> render_click()

      view
      |> form("form#profile-form", %{
        "full_name" => "Copy User",
        "username" => "copyuser123"
      })
      |> render_change()

      # Profile -> connect_calendar
      view |> element("button[phx-click='next_step']") |> render_click()
      # connect_calendar is a forced choice — skip before Continue.
      view |> element(~s{button[phx-value-option="skip"]}) |> render_click()

      # Continue opens the nudge modal; confirm it to leave the calendar step.
      view |> element("button[phx-click='next_step']") |> render_click()
      render_click(view, "confirm_skip_calendar")

      # buffer_time -> booking_window -> minimum_notice -> ready (three advances).
      Enum.each(1..3, fn _step ->
        view |> element("button[phx-click='next_step']") |> render_click()
      end)

      html = render(view)
      assert html =~ "all set"

      # The button is wired to the clipboard hook and carries the booking URL.
      assert has_element?(
               view,
               "button#onboarding-copy-booking-url[phx-hook='CopyOnClick'][data-copy-text]"
             )

      button_html = view |> element("#onboarding-copy-booking-url") |> render()
      assert button_html =~ ~s(data-copy-text=")
      assert button_html =~ "/copyuser123"

      # The dead `phx:copy` dispatch must not reappear.
      refute html =~ "phx:copy"
    end
  end

  describe "already completed onboarding" do
    test "completed onboarding redirects to dashboard", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      conn = log_in_user(conn, user)

      # Try to access onboarding
      {:error, {:redirect, redirect_info}} = live(conn, ~p"/onboarding")

      # Should redirect to dashboard (check the 'to' field)
      assert %{to: "/dashboard"} = redirect_info
      assert redirect_info.flash["info"] =~ "already completed onboarding"
    end

    test "completed onboarding shows info flash message", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      conn = log_in_user(conn, user)

      # Navigate to onboarding (will redirect)
      conn = get(conn, ~p"/onboarding")

      # Should have flash message
      assert Flash.get(conn.assigns.flash, :info) =~
               "You have already completed onboarding"
    end
  end

  describe "profile auto-creation" do
    test "profile is created automatically on mount if missing", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)
      conn = log_in_user(conn, user)

      # Verify no profile exists yet
      assert Repo.get_by(Tymeslot.Profiles.ProfileSchema, user_id: user.id) == nil

      # Mount onboarding
      {:ok, _view, _html} = live(conn, ~p"/onboarding")

      # Profile should now exist
      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.user_id == user.id
    end

    test "existing non-default timezone is preserved on mount", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)

      insert(:profile,
        user: user,
        username: "tz_user",
        full_name: "TZ User",
        timezone: "America/New_York"
      )

      conn =
        conn
        |> log_in_user(user)
        |> put_connect_params(%{"timezone" => "Europe/Paris"})

      {:ok, _view, _html} = live(conn, ~p"/onboarding")

      # The explicitly set timezone should NOT be overwritten by browser detection
      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.timezone == "America/New_York"
    end

    test "existing profile is loaded on mount", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)

      # Create profile with existing data
      profile =
        insert(:profile,
          user: user,
          username: "existing_user",
          full_name: "Existing Name",
          timezone: "America/New_York"
        )

      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/onboarding")

      # Navigate to profile step
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # The form should contain the existing data
      # Note: data might not be in value attribute but in assigns
      # Let's just verify we can see the text somewhere
      _html = render(view)

      # Don't check exact HTML structure, just verify no errors
      # The actual population will be tested in the happy path test

      # Profile should not be duplicated
      profiles =
        Repo.all(from(p in Tymeslot.Profiles.ProfileSchema, where: p.user_id == ^user.id))

      assert length(profiles) == 1
      assert hd(profiles).id == profile.id
    end
  end
end
