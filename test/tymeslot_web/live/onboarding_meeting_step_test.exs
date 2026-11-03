defmodule TymeslotWeb.OnboardingLive.MeetingStepTest do
  @moduledoc """
  The meeting step: the host's meeting (name, length, place) and the week
  people can book it in, saved as the host edits, with the stage's times
  read again after a change that reshapes them.

  The host is a new account as sign-up leaves it (`Profiles.create_profile/1`
  seeds the meeting type and the week), with a bookable calendar stubbed at
  its boundary (`Tymeslot.CalendarMock`).
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :onboarding
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.CalendarMock
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup do
    test_pid = self()

    # Every read of the week reaches the calendar once; the test counts them.
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      send(test_pid, :week_read)
      {:ok, []}
    end)

    :ok
  end

  defp new_host do
    user = insert(:user, onboarding_completed_at: nil)
    {:ok, profile} = Profiles.create_profile(user.id)

    profile =
      profile
      |> Changeset.change(
        username: "meet#{System.unique_integer([:positive])}",
        timezone: "Etc/UTC"
      )
      |> Repo.update!()

    insert(:calendar_integration, user: user)
    %{user: user, profile: profile}
  end

  defp open_step(conn, user) do
    {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/meeting")
    render_async(view)
    assert_received :week_read
    view
  end

  defp meeting_types(user), do: MeetingTypes.get_all_meeting_types(user.id)

  defp week(profile) do
    schedule = Schedules.get_default(profile.id)

    schedule.id
    |> WeeklySchedule.get_weekly_schedule()
    |> Map.new(fn day -> {day.day_of_week, {day.is_available, day.start_time, day.end_time}} end)
  end

  defp continue_disabled?(view),
    do: has_element?(view, "button[phx-click='next_step'][disabled]")

  test "the meeting step edits the seeded type", %{conn: conn} do
    %{user: user} = new_host()
    [seeded] = meeting_types(user)
    view = open_step(conn, user)

    # The stage follows the name as it is typed, before any save.
    render_change(view, "meeting_change", %{"meeting" => %{"name" => "Consultation"}})

    assert has_element?(
             view,
             "#onboarding-stage [data-role='preview-meeting-name']",
             "Consultation"
           )

    assert [%{name: "Intro call"}] = meeting_types(user)

    render_blur(element(view, "#meeting-name"))
    view |> element("#meeting-duration-45") |> render_click()

    assert [%{id: id, name: "Consultation", duration_minutes: 45}] = meeting_types(user)
    assert id == seeded.id
    assert has_element?(view, "#onboarding-stage [data-role='preview-meeting-duration']", "45")
  end

  test "video without a provider saves a custom video location", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)

    view |> element("#meeting-location-video") |> render_click()

    assert [%{locations: [location], allow_video: false}] = meeting_types(user)
    assert %{kind: :custom, label: "Video call", details: nil} = location
    assert render(view) =~ "You&#39;ll send the link after booking."
  end

  test "video with a connected provider binds it", %{conn: conn} do
    %{user: user} = new_host()
    integration = insert(:video_integration, user: user, is_active: true)
    view = open_step(conn, user)

    view |> element("#meeting-location-video") |> render_click()

    assert [%{locations: [location], allow_video: true}] = meeting_types(user)
    assert %{kind: :video, video_integration_ids: [id]} = location
    assert id == integration.id
  end

  test "phone asks the booker for their number", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)

    view |> element("#meeting-location-phone") |> render_click()

    assert [%{locations: [%{kind: :phone, collect_from_guest: true}]}] = meeting_types(user)

    assert has_element?(
             view,
             "#onboarding-stage [data-role='preview-meeting-icon'][data-icon='hero-phone']"
           )
  end

  test "hours presets write the week", %{conn: conn} do
    %{user: user, profile: profile} = new_host()
    view = open_step(conn, user)

    view |> element("#meeting-hours-preset-mornings") |> render_click()

    week = week(profile)

    for day <- 1..5,
        do: assert(week[day] == {true, ~T[08:00:00], ~T[12:00:00]}, "day #{day}")

    assert {false, _start, _end} = week[6]
    assert {false, _start, _end} = week[7]
    assert has_element?(view, "#meeting-hours-preset-mornings[aria-pressed='true']")
  end

  test "a time change away from a preset shows Custom", %{conn: conn} do
    %{user: user, profile: profile} = new_host()
    view = open_step(conn, user)

    view
    |> element("#meeting-hours-form")
    |> render_change(%{"hours" => %{"start" => "10:00", "end" => "17:00"}})

    assert week(profile)[1] == {true, ~T[10:00:00], ~T[17:00:00]}
    assert has_element?(view, "#meeting-hours-preset-custom[aria-pressed='true']")
  end

  test "custom hours with no days are refused", %{conn: conn} do
    %{user: user, profile: profile} = new_host()
    view = open_step(conn, user)
    before = week(profile)

    for day <- 1..5, do: view |> element("#meeting-day-#{day}") |> render_click()

    assert has_element?(view, "[data-role='hours-error']", "Choose at least one day.")
    assert continue_disabled?(view)
    # The last day off was refused, so the week keeps that day.
    assert week(profile)[5] == before[5]
    assert {true, _start, _end} = week(profile)[5]
  end

  test "an end before the start is refused", %{conn: conn} do
    %{user: user, profile: profile} = new_host()
    view = open_step(conn, user)
    before = week(profile)

    view
    |> element("#meeting-hours-form")
    |> render_change(%{"hours" => %{"start" => "17:00", "end" => "09:00"}})

    assert has_element?(
             view,
             "[data-role='hours-error']",
             "Choose an end time after the start time."
           )

    assert continue_disabled?(view)
    assert week(profile) == before
  end

  test "a blank name is refused and keeps Continue disabled", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)

    render_change(view, "meeting_change", %{"meeting" => %{"name" => "  \u0000 "}})
    render_blur(element(view, "#meeting-name"))

    assert render(view) =~ "Give your meeting a name."
    assert continue_disabled?(view)
    assert [%{name: "Intro call"}] = meeting_types(user)
  end

  test "changing hours re-runs the preview", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    refute_received :week_read

    view |> element("#meeting-hours-preset-afternoons") |> render_click()
    render_async(view)

    assert_received :week_read
    # The new week replaces the old one under a new key, so it reveals.
    assert has_element?(view, "#stage-times-2 [data-reveal-item]")
  end

  test "renaming alone does not read the week again", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)

    view |> element("#meeting-name-suggestions-3") |> render_click()
    render_async(view)

    assert [%{name: "Coffee chat"}] = meeting_types(user)
    refute_received :week_read
  end

  test "Continue saves a name still being typed and moves on", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)

    render_change(view, "meeting_change", %{"meeting" => %{"name" => "Strategy session"}})
    view |> element("button[phx-click='next_step']") |> render_click()

    assert [%{name: "Strategy session"}] = meeting_types(user)
    assert has_element?(view, "#onboarding-step-heading-choose_theme")
  end
end
