defmodule TymeslotWeb.OnboardingLiveTest do
  @moduledoc """
  Happy path tests for the onboarding flow.

  Tests core user journeys including:
  - Complete onboarding end-to-end
  - Redirect behavior for already-onboarded users
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils
  @moduletag :onboarding

  import Ecto.Query
  import Mox
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import TymeslotWeb.OnboardingTestHelpers

  alias Phoenix.Flash
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "complete onboarding flow" do
    test "new user can complete full onboarding successfully", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)

      # A new host starts at their link
      assert has_element?(view, "#profile-form")

      view
      |> form("form#profile-form", %{"full_name" => "Test User", "username" => "testuser123"})
      |> render_change()

      # Link -> calendar -> meeting -> look -> live
      click_continue(view)
      assert has_element?(view, ".onboarding-provider-cards")
      click_continue(view)
      click_continue(view)
      click_continue(view)
      assert has_element?(view, ".onboarding-step-title", "You're live")

      # Live -> complete onboarding
      click_continue(view)
      assert_redirect(view, ~p"/dashboard")

      user = Repo.reload!(user)
      assert %DateTime{} = user.onboarding_completed_at

      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.full_name == "Test User"
      assert profile.username == "testuser123"
      # Without connect_params, timezone falls back to business default
      assert profile.timezone == "Europe/Tallinn"
    end

    test "onboarding persists all fields including detected timezone", %{conn: conn} do
      user = insert(:user, name: "Jane Doe", onboarding_completed_at: nil)
      insert(:calendar_integration, user: user)

      conn =
        conn
        |> log_in_user(user)
        |> put_connect_params(%{"timezone" => "Europe/Paris"})

      {:ok, view, _html} = live(conn, "/onboarding")

      view
      |> form("form#profile-form", %{
        "full_name" => "Jane Doe Updated",
        "username" => "janedoe2024"
      })
      |> render_change()

      # link -> calendar -> meeting -> look -> live -> complete
      Enum.each(1..5, fn _step -> click_continue(view) end)
      assert_redirect(view, ~p"/dashboard")

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

    test "an unrecognised detected timezone does not block saving the profile step", %{
      conn: conn
    } do
      {:ok, view, _html, user} =
        setup_onboarding(conn, %{name: "Odd Zone"}, nil,
          connect_params: %{"timezone" => "Etc/Unknown"}
        )

      view
      |> form("form#profile-form", %{"full_name" => "Odd Zone", "username" => "oddzone2024"})
      |> render_change()

      view |> element("button[phx-click='next_step']") |> render_click()

      assert has_element?(view, ".onboarding-provider-cards")
      refute render(view) =~ "Please check your input"

      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.username == "oddzone2024"
      assert profile.timezone == "Europe/Tallinn"
    end

    # A refusal that says what went wrong is shown as is, not replaced by the
    # generic "check your input" message.
    test "an exhausted username change allowance is named on the profile step", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn, %{name: "Busy Host"})
      key = "user:" <> Integer.to_string(user.id)
      for _n <- 1..6, do: RateLimiter.check(:username_change, key)

      view
      |> form("form#profile-form", %{"full_name" => "Busy Host", "username" => "busyhost2024"})
      |> render_change()

      view |> element("button[phx-click='next_step']") |> render_click()

      html = render(view)
      assert html =~ "Too many username change attempts. Please try again later."
      refute html =~ "Please check your input"
    end

    # The strict sanitiser drops everything from `--` onwards and strips
    # `0x<hex>` runs, so these once saved as "team" and "studio-".
    for username <- ~w(team--alpha studio-0xab1) do
      test "the profile step saves #{username} exactly as typed", %{conn: conn} do
        {:ok, view, _html, user} = setup_onboarding(conn, %{name: "Team Alpha"})

        view
        |> form("form#profile-form", %{
          "full_name" => "Team Alpha",
          "username" => unquote(username)
        })
        |> render_change()

        view |> element("button[phx-click='next_step']") |> render_click()

        assert has_element?(view, ".onboarding-provider-cards")

        profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
        assert profile.username == unquote(username)
      end
    end

    test "user name is pre-filled in profile step", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn, %{name: "Pre Filled Name"})

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
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)

      # Choose a username so the booking URL resolves.
      view
      |> form("form#profile-form", %{
        "full_name" => "Copy User",
        "username" => "copyuser123"
      })
      |> render_change()

      # link -> calendar -> meeting -> look -> live
      Enum.each(1..4, fn _step -> click_continue(view) end)

      html = render(view)
      assert has_element?(view, ".onboarding-step-title", "You're live")

      # The button is wired to the clipboard hook and carries the booking URL.
      assert has_element?(
               view,
               "button#onboarding-copy-booking-url[phx-hook='CopyOnClick'][data-copy-text]"
             )

      # Copying is the step's primary action, labelled in text, and reports
      # itself to the server since the copy itself never leaves the browser.
      assert has_element?(
               view,
               "button#onboarding-copy-booking-url.action-button--primary",
               "Copy booking link"
             )

      assert has_element?(
               view,
               "button#onboarding-copy-booking-url[phx-click='share_booking_link'][phx-value-channel='copy']"
             )

      # Finishing stays available but gives way to the share actions.
      assert has_element?(
               view,
               "button.action-button--secondary[phx-click='next_step']",
               "Go to dashboard"
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

      {:ok, view, _html} = live(conn, ~p"/onboarding/profile")

      # The profile step is drawn from the stored profile.
      assert render(view) =~ "existing_user"

      # Profile should not be duplicated
      profiles =
        Repo.all(from(p in Tymeslot.Profiles.ProfileSchema, where: p.user_id == ^user.id))

      assert length(profiles) == 1
      assert hd(profiles).id == profile.id
    end
  end
end
