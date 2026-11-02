defmodule TymeslotWeb.OnboardingNavigationTest do
  @moduledoc """
  Navigation tests for the onboarding flow: moving through the five steps,
  where a host resumes, which steps a deep link may reach, and the progress
  indicator.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import Mox
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import TymeslotWeb.OnboardingTestHelpers

  alias TymeslotWeb.OnboardingLive.NavigationHandlers

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  defp step_title(view) do
    view
    |> element(".onboarding-step-title")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
  end

  describe "forward navigation" do
    test "a host walks every step from the link to going live", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)

      assert has_element?(view, "#profile-form")
      assert step_title(view) == "Your link"

      navigate_to_calendar_step(view)
      assert step_title(view) == "Your calendar"
      assert has_element?(view, ".onboarding-provider-cards")

      click_continue(view)
      assert step_title(view) == "Your meeting"
      assert has_element?(view, "#onboarding-meeting-step")

      click_continue(view)
      assert step_title(view) == "Your look"

      click_continue(view)
      assert step_title(view) == "You're live"
      assert has_element?(view, "button[phx-click='next_step']", "Go to dashboard")
    end

    test "Continue reads the same on every step before the last", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)

      assert has_element?(view, "button[phx-click='next_step']", "Continue")
      navigate_to_calendar_step(view)
      assert has_element?(view, "button[phx-click='next_step']", "Continue")
      click_continue(view)
      assert has_element?(view, "button[phx-click='next_step']", "Continue")
      click_continue(view)
      assert has_element?(view, "button[phx-click='next_step']", "Continue")
      click_continue(view)
      refute has_element?(view, "button[phx-click='next_step']", "Continue")
    end
  end

  describe "backward navigation" do
    test "Back walks the steps in reverse to the link", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      navigate_to_theme_step(view)

      view |> element("button[phx-click='previous_step']") |> render_click()
      assert step_title(view) == "Your meeting"

      view |> element("button[phx-click='previous_step']") |> render_click()
      assert step_title(view) == "Your calendar"

      view |> element("button[phx-click='previous_step']") |> render_click()
      assert has_element?(view, "#profile-form")
      refute has_element?(view, "button[phx-click='previous_step']")
    end

    test "going back to the link shows the saved username", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      fill_basic_settings(view, "Changed Name", "changeduser")
      click_continue(view)

      view |> element("button[phx-click='previous_step']") |> render_click()

      assert has_element?(view, "#profile-form")
      assert render(view) =~ "changeduser"
    end

    test "the link step has no Back button", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      assert has_element?(view, "#profile-form")
      refute has_element?(view, "button[phx-click='previous_step']")
    end
  end

  describe "resuming" do
    test "/onboarding resumes at the first incomplete step", %{conn: conn} do
      {conn_new, _user} = onboarding_conn(conn)
      assert {:ok, view, _html} = live(conn_new, ~p"/onboarding")
      assert step_title(view) == "Your link"
      assert has_element?(view, "#profile-form")

      user = insert(:user, onboarding_completed_at: nil)
      insert(:profile, user: user, username: "resumer#{System.unique_integer([:positive])}")
      insert(:calendar_integration, user: user)

      {:ok, view, _html} =
        live(log_in_user(setup_onboarding_session(build_conn()), user), ~p"/onboarding")

      assert step_title(view) == "Your meeting"
    end

    test "a host with a username but no calendar resumes at the calendar", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)
      insert(:profile, user: user, username: "nocal#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/onboarding")
      assert step_title(view) == "Your calendar"
    end

    test "a later step without a calendar patches back to the calendar step", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)
      insert(:profile, user: user, username: "deeplink#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/onboarding/meeting")
      assert step_title(view) == "Your calendar"
      assert has_element?(view, ".onboarding-provider-cards")

      {:ok, view, _html} =
        live(
          log_in_user(setup_onboarding_session(build_conn()), user),
          ~p"/onboarding/choose_theme"
        )

      assert step_title(view) == "Your calendar"
    end

    test "an earlier step than the resume step stays where it was asked for", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)
      insert(:profile, user: user, username: "earlier#{System.unique_integer([:positive])}")
      insert(:calendar_integration, user: user)

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/onboarding/profile")
      assert has_element?(view, "#profile-form")
    end

    test "a retired or unknown step resumes like /onboarding", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)

      for step <- ~w(welcome buffer_time booking_window minimum_notice nonsense) do
        {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/#{step}")
        assert has_element?(view, "#profile-form"), "#{step} did not resume at the link"
      end
    end
  end

  describe "debug routes" do
    test "debug finish returns to the dev route" do
      assert NavigationHandlers.base_path("http://localhost:4000/dev/onboarding/ready") ==
               "/dev/onboarding"

      assert NavigationHandlers.base_path("http://localhost:4000/debug/onboarding/ready") ==
               "/debug/onboarding"

      assert NavigationHandlers.base_path("http://localhost:4000/onboarding/ready") ==
               "/onboarding"
    end
  end

  describe "progress indicator" do
    test "marks the steps before the current one as completed", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)

      assert has_element?(view, ".onboarding-progress-dot--current")
      refute has_element?(view, ".onboarding-progress-dot--completed")

      navigate_to_meeting_step(view)

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find(".onboarding-progress-dot--completed")
             |> length() == 2

      assert has_element?(view, ".onboarding-progress-label", "Step 3 of 5")
    end
  end
end
