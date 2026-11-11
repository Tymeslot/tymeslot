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

  alias Tymeslot.Repo
  alias TymeslotWeb.OnboardingLive
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
    |> String.trim()
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
      assert has_element?(view, "#onboarding-finish", "Go to dashboard")
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

  # A patch made while the LiveView mounts is not reported to the test, so
  # each test mounts on a step the host may see and then navigates to the one
  # under test, where the patch back can be asserted by its path.
  describe "resuming" do
    test "/onboarding resumes at the first incomplete step", %{conn: conn} do
      {:ok, view, _html} = live(host_conn(conn), ~p"/onboarding/profile")
      render_patch(view, ~p"/onboarding")
      assert_patch(view, ~p"/onboarding/profile")

      {:ok, view, _html} =
        live(host_conn(build_conn(), username: true, calendar: true), ~p"/onboarding/profile")

      render_patch(view, ~p"/onboarding")
      assert_patch(view, ~p"/onboarding/meeting")
      assert step_title(view) == "Your meeting"
    end

    test "a host with a username but no calendar resumes at the calendar", %{conn: conn} do
      {:ok, view, _html} = live(host_conn(conn, username: true), ~p"/onboarding/profile")
      render_patch(view, ~p"/onboarding")
      assert_patch(view, ~p"/onboarding/connect_calendar")
      assert step_title(view) == "Your calendar"
    end

    test "a later step without a calendar patches back to the calendar step", %{conn: conn} do
      conn = host_conn(conn, username: true)

      for step <- ~w(meeting choose_theme ready) do
        {:ok, view, _html} = live(conn, ~p"/onboarding/profile")
        render_patch(view, "/onboarding/#{step}")
        assert_patch(view, ~p"/onboarding/connect_calendar")
        assert has_element?(view, ".onboarding-provider-cards")
      end
    end

    test "a deep link straight to a later step lands on the calendar step", %{conn: conn} do
      {:ok, view, _html} = live(host_conn(conn, username: true), ~p"/onboarding/ready")
      assert step_title(view) == "Your calendar"
    end

    test "a host without a username is sent back to the link", %{conn: conn} do
      conn = host_conn(conn, calendar: true)

      {:ok, view, _html} = live(conn, ~p"/onboarding/profile")
      render_patch(view, ~p"/onboarding/meeting")
      assert_patch(view, ~p"/onboarding/profile")

      {:ok, view, _html} = live(conn, ~p"/onboarding/meeting")
      assert has_element?(view, "#profile-form")
    end

    test "an earlier step than the resume step stays where it was asked for", %{conn: conn} do
      conn = host_conn(conn, username: true, calendar: true)

      {:ok, view, _html} = live(conn, ~p"/onboarding/profile")
      assert has_element?(view, "#profile-form")

      render_patch(view, ~p"/onboarding/connect_calendar")
      assert step_title(view) == "Your calendar"
    end

    test "a retired or unknown step resumes like /onboarding", %{conn: conn} do
      conn = host_conn(conn)

      for step <- ~w(welcome buffer_time booking_window minimum_notice nonsense onboarding) do
        {:ok, view, _html} = live(conn, ~p"/onboarding/profile")
        render_patch(view, "/onboarding/#{step}")
        assert_patch(view, ~p"/onboarding/profile")
      end
    end

    test "a debug fixture is ignored on the real routes", %{conn: conn} do
      conn = host_conn(conn, username: true)

      {:ok, view, _html} = live(conn, ~p"/onboarding/connect_calendar")
      render_patch(view, "/onboarding/meeting?fixture=calendar")
      assert_patch(view, "/onboarding/connect_calendar?fixture=calendar")

      {:ok, view, _html} = live(conn, "/onboarding/meeting?fixture=calendar")
      assert step_title(view) == "Your calendar"
      refute has_element?(view, "div.onboarding-connected-calendar")
    end

    # Only the calendar provider's return path carries the flag; on any other
    # step it would make the calendar step skip straight to going live later.
    test "the share-step return flag only counts on the calendar step", %{conn: conn} do
      conn = host_conn(conn, username: true, calendar: true)

      {:ok, view, _html} = live(conn, "/onboarding/meeting?return=share")
      view |> element("button[phx-click='previous_step']") |> render_click()
      assert step_title(view) == "Your calendar"

      click_continue(view)
      assert step_title(view) == "Your meeting"
    end
  end

  # The address names the step on screen, so a reload lands where the host
  # was and the browser's Back and Forward move through the steps.
  # The look and the live step wait until the host has been through the
  # meeting step, however they try to get there.
  describe "the meeting step gate" do
    test "a typed /onboarding/ready lands on the meeting until it is confirmed", %{conn: conn} do
      {:ok, view, _html} =
        live(host_conn(conn, username: true, calendar: true), "/onboarding/ready")

      assert step_title(view) == "Your meeting"
      refute has_element?(view, "#onboarding-finish")
    end

    test "a typed later step patches back to the meeting", %{conn: conn} do
      {:ok, view, _html} =
        live(host_conn(conn, username: true, calendar: true), ~p"/onboarding/meeting")

      for step <- ~w(ready choose_theme) do
        render_patch(view, "/onboarding/#{step}")
        assert_patch(view, ~p"/onboarding/meeting")
        assert step_title(view) == "Your meeting"
      end
    end

    test "the first paint draws the meeting too, not the step that was typed", %{conn: conn} do
      html =
        host_conn(conn, username: true, calendar: true)
        |> get("/onboarding/ready")
        |> html_response(200)

      assert html =~ ~s(id="onboarding-meeting-step")
    end

    test "Continue on the meeting step opens the later steps, for good", %{conn: conn} do
      user = host_user(username: true, calendar: true)
      conn = log_in_user(setup_onboarding_session(conn), user)
      {:ok, view, _html} = live(conn, ~p"/onboarding/meeting")
      assert Repo.reload!(user).onboarding_meeting_confirmed_at == nil

      click_continue(view)

      assert step_title(view) == "Your look"
      assert %DateTime{} = Repo.reload!(user).onboarding_meeting_confirmed_at

      {:ok, reloaded, _html} = live(conn, "/onboarding/ready")
      assert step_title(reloaded) == "You're live"

      {:ok, resumed, _html} = live(conn, "/onboarding")
      assert step_title(resumed) == "Your look"
    end

    test "a meeting step left in error is not confirmed", %{conn: conn} do
      user = host_user(username: true, calendar: true)
      conn = log_in_user(setup_onboarding_session(conn), user)
      {:ok, view, _html} = live(conn, ~p"/onboarding/meeting")

      render_change(view, "meeting_change", %{"meeting" => %{"name" => "  "}})
      render_click(view, "next_step", %{})

      assert step_title(view) == "Your meeting"
      assert Repo.reload!(user).onboarding_meeting_confirmed_at == nil
    end

    # What the migration stamps for a host mid-onboarding whose meeting type
    # is no longer the seeded default.
    test "an account already marked as confirmed is not sent back", %{conn: conn} do
      user =
        host_user(
          username: true,
          calendar: true,
          onboarding_meeting_confirmed_at: DateTime.utc_now(:second)
        )

      conn = log_in_user(setup_onboarding_session(conn), user)

      {:ok, view, _html} = live(conn, "/onboarding/ready")
      assert step_title(view) == "You're live"
    end

    test "a completed onboarding counts as confirmed without the marker", %{conn: conn} do
      user =
        host_user(
          username: true,
          calendar: true,
          onboarding_completed_at: DateTime.utc_now(:second)
        )

      assert user.onboarding_meeting_confirmed_at == nil
      conn = log_in_user(setup_onboarding_session(conn), user)

      # The live step stays open for an hour after completion.
      {:ok, view, _html} = live(conn, "/onboarding/ready")
      assert step_title(view) == "You're live"
    end

    test "the share-step return flag cannot skip a meeting never confirmed", %{conn: conn} do
      {:ok, view, _html} =
        live(
          host_conn(conn, username: true, calendar: true),
          "/onboarding/connect_calendar?return=share"
        )

      click_continue(view)

      assert step_title(view) == "Your meeting"
    end

    # The debug routes exist to look at any step on demand. They are mounted
    # only where `:dev_routes` is set, so the handler is driven directly, on
    # the disconnected render where the landing step is chosen.
    test "a debug route opens the later steps, the real route does not" do
      user = insert(:user, onboarding_completed_at: nil)
      profile = insert(:profile, user: user, username: "debughost")

      landing = fn live_action ->
        socket = %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            flash: %{},
            current_user: user,
            profile: profile,
            booking_page_live: true,
            patched_step: nil,
            live_action: live_action
          }
        }

        {:noreply, socket} =
          OnboardingLive.handle_params(
            %{"step" => "ready"},
            "http://localhost:4000/onboarding/ready",
            socket
          )

        socket.assigns.current_step
      end

      assert landing.(:debug_step) == :ready
      assert landing.(nil) == :meeting
    end
  end

  describe "the address follows the step" do
    test "Continue patches the address to each step in turn", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)

      navigate_to_calendar_step(view)
      assert_patch(view, ~p"/onboarding/connect_calendar")

      for step <- ~w(meeting choose_theme ready) do
        click_continue(view)
        assert_patch(view, "/onboarding/#{step}")
      end

      assert step_title(view) == "You're live"
    end

    test "Back patches the address to the step before", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      navigate_to_meeting_step(view)
      assert_patch(view, ~p"/onboarding/connect_calendar")
      assert_patch(view, ~p"/onboarding/meeting")

      view |> element("button[phx-click='previous_step']") |> render_click()

      assert_patch(view, ~p"/onboarding/connect_calendar")
      assert step_title(view) == "Your calendar"
    end

    test "reloading the address lands on the step that was on screen", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      navigate_to_theme_step(view)

      for step <- ~w(connect_calendar meeting choose_theme),
          do: assert_patch(view, "/onboarding/#{step}")

      conn = log_in_user(setup_onboarding_session(build_conn()), user)
      {:ok, reloaded, _html} = live(conn, ~p"/onboarding/choose_theme")

      assert step_title(reloaded) == "Your look"
    end

    test "the browser's Back draws the earlier step from what is saved", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      fill_profile(view, "Saved Name", "savedhost#{System.unique_integer([:positive])}")
      click_continue(view)
      assert_patch(view, ~p"/onboarding/connect_calendar")

      render_patch(view, ~p"/onboarding/profile")

      assert has_element?(view, "#profile-form")
      assert has_element?(view, "#full_name[value='Saved Name']")

      # Forward again, to a step the account may reach.
      render_patch(view, ~p"/onboarding/meeting")
      assert step_title(view) == "Your meeting"
      assert has_element?(view, "#onboarding-meeting-step")
    end

    test "the way back from the share step carries its return flag, and leads back to it",
         %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      navigate_to_ready_step(view)

      for step <- ~w(connect_calendar meeting choose_theme ready),
          do: assert_patch(view, "/onboarding/#{step}")

      render_click(view, "return_to_calendar_step", %{})
      assert_patch(view, "/onboarding/connect_calendar?return=share")

      click_continue(view)
      assert_patch(view, ~p"/onboarding/ready")
      assert step_title(view) == "You're live"
    end
  end

  describe "debug routes" do
    test "after a keep, finishing on a debug route goes back to where it started" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_step: :ready,
          kept_method: "copy",
          live_action: :debug_step,
          base_path: "/dev/onboarding"
        }
      }

      assert {:noreply, %{redirected: {:redirect, %{to: "/dev/onboarding"}}}} =
               NavigationHandlers.handle_next_step(socket)
    end

    # A debug route on an account that finished onboarding long ago has
    # nothing left to complete, so Finish stays open without a keep, and
    # does not pretend a keep happened.
    defp unkept_ready_socket(live_action, user) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_step: :ready,
          kept_method: nil,
          booking_page_live: true,
          current_user: user,
          live_action: live_action,
          base_path: "/dev/onboarding"
        }
      }
    end

    test "a settled account finishes a debug route without a keep" do
      socket = unkept_ready_socket(:debug_step, %{onboarding_completed_at: DateTime.utc_now()})

      refute NavigationHandlers.finish_locked?(socket.assigns)

      assert {:noreply, %{redirected: {:redirect, %{to: "/dev/onboarding"}}}} =
               NavigationHandlers.handle_next_step(socket)
    end

    test "a host still in setup must keep the link first, debug route or not" do
      for action <- [:debug_step, nil] do
        socket = unkept_ready_socket(action, %{onboarding_completed_at: nil})
        assert NavigationHandlers.finish_locked?(socket.assigns)
        assert {:noreply, %{redirected: nil}} = NavigationHandlers.handle_next_step(socket)
      end

      # On the real route even a settled account keeps the lock: it only
      # reaches the step within the reconnect hour, to keep its link.
      settled = unkept_ready_socket(nil, %{onboarding_completed_at: DateTime.utc_now()})
      assert NavigationHandlers.finish_locked?(settled.assigns)
    end

    test "debug finish returns to the dev route" do
      assert NavigationHandlers.base_path("http://localhost:4000/dev/onboarding/ready") ==
               "/dev/onboarding"

      assert NavigationHandlers.base_path("http://localhost:4000/debug/onboarding/ready") ==
               "/debug/onboarding"

      assert NavigationHandlers.base_path("http://localhost:4000/onboarding/ready") ==
               "/onboarding"
    end

    test "a step named onboarding on the real route is not read as a debug prefix" do
      assert NavigationHandlers.base_path("http://localhost:4000/onboarding/onboarding") ==
               "/onboarding"
    end
  end

  # A logged-in host who has not finished onboarding, with a saved username
  # and a bookable calendar when asked for.
  defp host_conn(conn, opts \\ []),
    do: log_in_user(setup_onboarding_session(conn), host_user(opts))

  # `:username` and `:calendar` set up those halves of the account; anything
  # else is an attribute of the user.
  defp host_user(opts) do
    {setup, attrs} = Keyword.split(opts, [:username, :calendar])
    user = insert(:user, Keyword.put_new(attrs, :onboarding_completed_at, nil))

    if setup[:username],
      do: insert(:profile, user: user, username: "host#{System.unique_integer([:positive])}")

    if setup[:calendar], do: insert(:calendar_integration, user: user)

    user
  end

  describe "progress indicator" do
    test "marks the steps before the current one as done", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)

      assert segment_states(view) == ~w(current upcoming upcoming upcoming upcoming)

      navigate_to_meeting_step(view)

      assert segment_states(view) == ~w(done done current upcoming upcoming)
      assert has_element?(view, ~s([data-role="onboarding-step-label"]), "Step 3 of 5")
    end
  end

  defp segment_states(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(".onboarding-progress-segment")
    |> Enum.flat_map(&Floki.attribute(&1, "data-state"))
  end
end
