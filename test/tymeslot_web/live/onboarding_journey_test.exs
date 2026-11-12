defmodule TymeslotWeb.OnboardingJourneyTest do
  @moduledoc """
  The onboarding wizard walked end to end, one test per way a new host can
  leave it: through all five steps to a kept link and the dashboard, away
  before keeping (and back into the wizard), and away right after keeping.

  The host starts as sign-up leaves them (`Profiles.create_profile/1` seeds
  the meeting type and the week, and no username is chosen yet). Their
  calendar is stubbed at its boundary (`Tymeslot.CalendarMock`), and
  connecting it is an inserted integration followed by a fresh mount, as
  the OAuth return is.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :onboarding

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias TymeslotWeb.BookingDriver.Page

  setup :verify_on_exit!

  setup do
    stub_free_calendar()
    :ok
  end

  # A host as sign-up leaves them: an account, and a profile with the seeded
  # meeting type and week but no link of their own yet.
  defp new_host(conn) do
    user = insert(:user, onboarding_completed_at: nil)
    {:ok, profile} = Profiles.create_profile(user.id)
    assert Profiles.default_username?(profile.username, user.id)
    %{user: user, conn: conn |> setup_onboarding_session() |> log_in_user(user)}
  end

  defp profile(user), do: Repo.get_by!(ProfileSchema, user_id: user.id)
  defp reload(user), do: Repo.get!(UserSchema, user.id)

  defp on_step?(view, step), do: has_element?(view, "#onboarding-step-heading-#{step}")

  defp continue_disabled?(view),
    do: has_element?(view, "button[phx-click='next_step'][disabled]")

  defp finish_locked?(view), do: has_element?(view, ~s(#onboarding-finish[aria-disabled="true"]))

  defp week(user) do
    user
    |> profile()
    |> Map.fetch!(:id)
    |> Schedules.get_default()
    |> Map.fetch!(:id)
    |> WeeklySchedule.get_weekly_schedule()
    |> Map.new(fn day -> {day.day_of_week, {day.is_available, day.start_time, day.end_time}} end)
  end

  # Link -> calendar: the suggested link is kept as it is. The calendar step
  # cannot be passed without a calendar.
  defp walk_to_calendar(conn) do
    {:ok, view, _html} = live(conn, "/onboarding")
    assert on_step?(view, :profile)

    [suggested] =
      view |> render() |> Floki.parse_document!() |> Floki.attribute("#username", "value")

    assert suggested != ""

    click_continue(view)
    assert on_step?(view, :connect_calendar)
    assert continue_disabled?(view)
    {view, suggested}
  end

  # The OAuth return: the calendar now exists and the step mounts afresh,
  # reading the week behind the reveal.
  defp connect_calendar(conn, user) do
    insert(:calendar_integration, user: user)
    {:ok, view, _html} = live(conn, "/onboarding/connect_calendar")
    render_async(view)

    assert has_element?(view, ~s([data-week-state="ready"]))
    refute continue_disabled?(view)
    view
  end

  # Meeting -> look -> live, with the meeting the plan names.
  defp walk_to_ready(view) do
    click_continue(view)
    assert on_step?(view, :meeting)

    # "Consultation" is one of the step's name chips.
    view |> element("#meeting-name-suggestions-1", "Consultation") |> render_click()
    view |> element("#meeting-duration-45") |> render_click()
    view |> element("#meeting-location-video") |> render_click()
    view |> element("#meeting-hours-preset-mornings") |> render_click()

    click_continue(view)
    assert on_step?(view, :choose_theme)

    # A theme other than the one already chosen, so the pick is observable.
    assert [theme | _others] =
             Page.attribute(
               view,
               ~s(button[data-testid="theme-thumbnail"][aria-pressed="false"]),
               "phx-value-theme"
             )

    view
    |> element(~s(button[data-testid="theme-thumbnail"][phx-value-theme="#{theme}"]))
    |> render_click()

    click_continue(view)
    assert on_step?(view, :ready)
    assert has_element?(view, ".onboarding-step-title", "You're live")
    {view, theme}
  end

  test "a new host goes from signup state to a kept link in five steps", %{conn: conn} do
    %{user: user, conn: conn} = new_host(conn)

    {_view, suggested} = walk_to_calendar(conn)
    assert profile(user).username == suggested

    {view, theme} = conn |> connect_calendar(user) |> walk_to_ready()
    assert finish_locked?(view)
    assert reload(user).onboarding_completed_at == nil

    view |> element("#onboarding-keep-copy") |> render_click()
    refute finish_locked?(view)

    view |> element("#onboarding-finish") |> render_click()
    assert_redirect(view, "/dashboard")
    assert {:ok, _dashboard, _html} = live(conn, "/dashboard")

    # The meeting: the seeded type, edited in place.
    assert [%{name: "Consultation", duration_minutes: 45}] =
             MeetingTypes.get_all_meeting_types(user.id)

    # The week: mornings, Monday to Friday.
    week = week(user)

    for day <- 1..5,
        do: assert(week[day] == {true, ~T[08:00:00], ~T[12:00:00]}, "day #{day}")

    assert {false, _start, _end} = week[6]
    assert {false, _start, _end} = week[7]

    profile = profile(user)
    assert profile.booking_theme == theme
    assert %DateTime{} = profile.booking_link_first_shared_at
    assert %DateTime{} = reload(user).onboarding_completed_at

    # The page is live for anyone.
    assert LinkAccessPolicy.check_public_readiness(profile) == {:ok, :ready}
    {:ok, page, _html} = live(build_conn(), "/#{suggested}")
    assert Page.assigns(page)[:scheduling_error_message] == nil
  end

  test "a host who leaves before keeping cannot reach the dashboard and resumes inside the wizard",
       %{conn: conn} do
    %{user: user, conn: conn} = new_host(conn)
    walk_to_calendar(conn)
    {view, _theme} = conn |> connect_calendar(user) |> walk_to_ready()
    assert finish_locked?(view)

    # Gone without keeping: nothing was completed or shared.
    assert reload(user).onboarding_completed_at == nil
    assert profile(user).booking_link_first_shared_at == nil

    # The meeting is confirmed, so the host resumes at the look
    # (`StepConfig.resume_step/1`), not at the live step they left.
    {:ok, resumed, _html} = live(conn, "/onboarding")
    assert on_step?(resumed, :choose_theme)

    assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, "/dashboard")
  end

  test "a host who keeps and closes the tab is done", %{conn: conn} do
    %{user: user, conn: conn} = new_host(conn)
    walk_to_calendar(conn)
    {view, _theme} = conn |> connect_calendar(user) |> walk_to_ready()

    view |> element("#onboarding-keep-email") |> render_click()
    assert %DateTime{} = reload(user).onboarding_completed_at
    assert %DateTime{} = profile(user).booking_link_first_shared_at

    # The tab is closed without "Go to dashboard"; the next visit is the
    # dashboard itself.
    assert {:ok, _dashboard, html} = live(conn, "/dashboard")
    assert html =~ ~s(id="dashboard-root")
  end
end
