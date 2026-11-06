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
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup do
    test_pid = self()
    AvailabilityCache.clear_all()

    # A refresh waits for further changes before it reads the week; out of
    # the way unless a test watches for it (`watch_refreshes/1`).
    Application.put_env(:tymeslot, :onboarding_week_refresh_after_ms, 60_000)
    on_exit(fn -> Application.delete_env(:tymeslot, :onboarding_week_refresh_after_ms) end)

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

  # Shortens the refresh wait and traces the LiveView, so a test can wait
  # for each refresh timer to reach it (`await_refreshes/2`) instead of
  # sleeping.
  # The coalescing window defaults to 20ms so most tests wait little; the
  # coalescing test widens it so a loaded machine cannot let the timer fire
  # between two clicks.
  defp watch_refreshes(view, window_ms \\ 20) do
    Application.put_env(:tymeslot, :onboarding_week_refresh_after_ms, window_ms)
    :erlang.trace(view.pid, true, [:receive])
  end

  defp await_refreshes(view, count) do
    for _n <- 1..count do
      assert_receive {:trace, _pid, :receive, {:week_preview_refresh, _token}}, 5_000
    end

    render_async(view)
  end

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

  test "a preset week hides the day and time controls until Custom", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)

    refute has_element?(view, "#meeting-day-1")
    refute has_element?(view, "#meeting-hours-form")

    view |> element("#meeting-hours-preset-custom") |> render_click()

    assert has_element?(view, "#meeting-day-1[aria-pressed='true']")
    assert has_element?(view, "#meeting-hours-form")
  end

  # Once open, an edit that lands back on a preset's week leaves the
  # controls in place under the host's hand.
  test "the controls stay open when an edit lands on a preset", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    view |> element("#meeting-hours-preset-custom") |> render_click()

    view |> element("#meeting-day-6") |> render_click()
    view |> element("#meeting-day-6") |> render_click()

    assert has_element?(view, "#meeting-hours-preset-weekdays[aria-pressed='true']")
    assert has_element?(view, "#meeting-day-1")
  end

  test "a week no preset describes shows the controls from the start", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    view |> element("#meeting-hours-preset-custom") |> render_click()
    view |> element("#meeting-day-6") |> render_click()

    {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/meeting")

    assert has_element?(view, "#meeting-hours-preset-custom[aria-pressed='true']")
    assert has_element?(view, "#meeting-day-6[aria-pressed='true']")
  end

  test "a time change away from a preset shows Custom", %{conn: conn} do
    %{user: user, profile: profile} = new_host()
    view = open_step(conn, user)
    view |> element("#meeting-hours-preset-custom") |> render_click()

    view
    |> element("#meeting-hours-form")
    |> render_change(%{"hours" => %{"start" => "10:00", "end" => "17:00"}})

    assert week(profile)[1] == {true, ~T[10:00:00], ~T[17:00:00]}
    assert has_element?(view, "#meeting-hours-preset-custom[aria-pressed='true']")
  end

  # A voice command that reads a day's button ("click Mon") must find it,
  # so the name is the short form shown, and the full name its description.
  test "each day is named by the text it shows", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    view |> element("#meeting-hours-preset-custom") |> render_click()

    [monday] = view |> render() |> Floki.parse_document!() |> Floki.find("#meeting-day-1")

    assert Floki.attribute(monday, "aria-label") == []
    assert monday |> Floki.text() |> String.trim() == "Mon"
    assert Floki.attribute(monday, "title") == ["Monday"]
  end

  test "custom hours with no days are refused", %{conn: conn} do
    %{user: user, profile: profile} = new_host()
    view = open_step(conn, user)
    view |> element("#meeting-hours-preset-custom") |> render_click()
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
    view |> element("#meeting-hours-preset-custom") |> render_click()
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

  test "changing hours rebuilds the preview without reading the calendar again", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    watch_refreshes(view)

    view |> element("#meeting-hours-preset-afternoons") |> render_click()
    await_refreshes(view, 1)

    # The new week replaces the old one under a new key, so it reveals,
    # folded over the calendar events already cached.
    assert has_element?(view, "#stage-times-2 [data-reveal-item]")
    refute_received :week_read
  end

  test "changes close together rebuild the preview once", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    view |> element("#meeting-hours-preset-custom") |> render_click()
    watch_refreshes(view, 1_500)

    for day <- [6, 7, 6, 7, 1], do: view |> element("#meeting-day-#{day}") |> render_click()
    await_refreshes(view, 5)

    assert has_element?(view, "#stage-times-2")
    refute has_element?(view, "#stage-times-3")
    refute_received :week_read
  end

  test "a duration save rebuilds the preview", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    watch_refreshes(view)

    view |> element("#meeting-duration-60") |> render_click()
    await_refreshes(view, 1)

    assert has_element?(view, "#stage-times-2 [data-reveal-item]")
  end

  test "a location save rebuilds the preview", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    watch_refreshes(view)

    view |> element("#meeting-location-phone") |> render_click()
    await_refreshes(view, 1)

    assert has_element?(view, "#stage-times-2 [data-reveal-item]")
  end

  test "renaming alone does not rebuild the preview", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    watch_refreshes(view)

    view |> element("#meeting-name-suggestions-3") |> render_click()

    assert [%{name: "Coffee chat"}] = meeting_types(user)
    refute_receive {:trace, _pid, :receive, {:week_preview_refresh, _token}}, 200
    assert has_element?(view, "#stage-times-1")
  end

  test "a rebuild that fails keeps the week shown and says so", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)
    watch_refreshes(view)

    # Nothing cached and a calendar that now fails: the rebuild has to read it.
    AvailabilityCache.clear_all()

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      {:error, :timeout}
    end)

    view |> element("#meeting-hours-preset-afternoons") |> render_click()
    await_refreshes(view, 1)

    assert has_element?(view, "#stage-times-1 [data-reveal-item]")
    assert has_element?(view, ".onboarding-stage-caption", "The preview couldn't update just now")
  end

  describe "an \"Other\" length" do
    setup %{conn: conn} do
      %{user: user} = new_host()
      view = open_step(conn, user)
      view |> element("#meeting-duration-other") |> render_click()
      %{user: user, view: view}
    end

    defp other_length(view, value) do
      render_change(view, "meeting_change", %{"meeting" => %{"duration_input" => value}})
      render_blur(element(view, "#meeting-duration-minutes"))
    end

    test "in range is saved", %{user: user, view: view} do
      other_length(view, "50")
      assert [%{duration_minutes: 50}] = meeting_types(user)
      refute continue_disabled?(view)
    end

    for value <- ["500", "52"] do
      test "#{value} is refused", %{user: user, view: view} do
        other_length(view, unquote(value))

        assert has_element?(view, "#meeting-duration-error", "Choose a length from 5 to 480")
        assert has_element?(view, "[aria-describedby='meeting-duration-error']")
        assert continue_disabled?(view)
        assert [%{duration_minutes: 30}] = meeting_types(user)
      end
    end
  end

  test "a week whose days differ shows Custom, and an off-grid time as it is", %{conn: conn} do
    %{user: user, profile: profile} = new_host()
    schedule = Schedules.get_default(profile.id)

    {:ok, _day} =
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[09:15:00],
        end_time: ~T[17:00:00]
      })

    view = open_step(conn, user)

    assert has_element?(view, "#meeting-hours-preset-custom[aria-pressed='true']")
    assert has_element?(view, "#meeting-hours-start option[value='09:15'][selected]")
  end

  describe "the name suggestions" do
    test "leave out a name another meeting type already uses", %{conn: conn} do
      %{user: user} = new_host()
      [seeded] = meeting_types(user)
      seeded |> Changeset.change(name: "Discovery") |> Repo.update!()
      insert(:meeting_type, user: user, name: "Intro call", sort_order: 10)
      view = open_step(conn, user)

      refute has_element?(view, "#meeting-name-suggestions button", "Intro call")
      assert has_element?(view, "#meeting-name-suggestions-1", "Consultation")

      # Sent anyway (a stale page), it is ignored rather than saved and refused.
      render_click(view, "meeting_suggestion", %{"index" => "0"})
      assert %{name: "Discovery"} = MeetingTypes.get_meeting_type(seeded.id, user.id)
      refute continue_disabled?(view)
    end

    test "keep the edited type's own name, and count an archived type's", %{conn: conn} do
      %{user: user} = new_host()
      insert(:meeting_type, user: user, name: "Consultation", sort_order: 10, is_active: false)
      view = open_step(conn, user)

      assert has_element?(view, "#meeting-name-suggestions-0[aria-pressed='true']", "Intro call")
      refute has_element?(view, "#meeting-name-suggestions button", "Consultation")
    end
  end

  test "a name refused by the save is named beside the disabled Continue", %{conn: conn} do
    %{user: user} = new_host()
    insert(:meeting_type, user: user, name: "Strategy session", sort_order: 10)
    view = open_step(conn, user)
    refute has_element?(view, "#onboarding-nav-hint")

    render_change(view, "meeting_change", %{"meeting" => %{"name" => "Strategy session"}})
    render_blur(element(view, "#meeting-name"))

    assert continue_disabled?(view)

    assert has_element?(
             view,
             "#onboarding-nav #onboarding-nav-hint",
             "You already have a meeting type with this name"
           )

    assert has_element?(
             view,
             "button[phx-click='next_step'][aria-describedby='onboarding-nav-hint']"
           )
  end

  test "Continue saves a name still being typed and moves on", %{conn: conn} do
    %{user: user} = new_host()
    view = open_step(conn, user)

    render_change(view, "meeting_change", %{"meeting" => %{"name" => "Strategy session"}})
    view |> element("button[phx-click='next_step']") |> render_click()

    assert [%{name: "Strategy session"}] = meeting_types(user)
    assert has_element?(view, "#onboarding-step-heading-choose_theme")
  end

  describe "malformed events" do
    test "params that are missing or not strings leave the session running", %{conn: conn} do
      %{user: user} = new_host()
      view = open_step(conn, user)

      for {event, params} <- [
            {"meeting_suggestion", %{"index" => 1}},
            {"meeting_duration", %{"duration" => 30}},
            {"hours_toggle_day", %{"day" => [1]}},
            {"hours_preset", %{}},
            {"reconnect_calendar", %{"id" => 1}},
            {"meeting_change", %{"meeting" => %{"duration_input" => 45}}}
          ] do
        render_hook(view, event, params)
      end

      assert Process.alive?(view.pid)
      assert [%{duration_minutes: 30}] = meeting_types(user)
    end
  end
end
