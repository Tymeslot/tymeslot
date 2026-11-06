defmodule TymeslotWeb.E2E.OnboardingTest do
  @moduledoc """
  The five-step onboarding wizard in a real browser, at a desktop and a
  phone width: link, calendar, meeting, look, live, then the dashboard.
  On every step the way on (Continue, or from lg the live step's finish)
  is on screen, and at the desktop size, a 1440×900-class screen, the
  question column holds the whole step with nothing to scroll
  (`assert_fits/1`). The window is taller than that: the page gets what its
  frame leaves.

  The calendar is stubbed at its boundary, as in every test run
  (`config :tymeslot, :calendar_module, Tymeslot.CalendarMock`, answered
  globally by `BrowserCase`), so no real provider is reached. Connecting it
  is an inserted integration and a fresh visit to the calendar step, as the
  OAuth return is.
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :onboarding

  import TymeslotWeb.OnboardingTestHelpers, only: [stub_free_calendar: 0]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  @continue "button[phx-click='next_step']"

  # The way on's place on screen, and how far the question column scrolls
  # (from lg; below it the page scrolls as one). A phone's live step has no
  # pinned way on: its finish ends the page.
  @layout_js """
  const way =
    document.querySelector('[data-role="onboarding-nav"] button[phx-click="next_step"]') ||
    (innerWidth >= 1024 && document.querySelector('#onboarding-finish'));
  const inner = document.querySelector('.onboarding-panel-inner');
  const r = way && way.getBoundingClientRect();
  return {
    way_in_view: !way || (r.top >= 0 && r.bottom <= innerHeight + 1),
    desktop: innerWidth >= 1024,
    height: innerHeight,
    column_overflow: inner.scrollHeight - inner.clientHeight
  };
  """

  setup do
    stub_free_calendar()
    :ok
  end

  feature "a new host walks the wizard to the dashboard at desktop width", %{session: session} do
    walk_the_wizard(session, {1440, 1050})
  end

  feature "a new host walks the wizard to the dashboard at phone width", %{session: session} do
    walk_the_wizard(session, {375, 812})
  end

  defp walk_the_wizard(session, size) do
    user = new_host()

    session
    |> log_in(user, size)
    |> link_step()
    |> calendar_step(user)
    |> meeting_step()
    |> look_step()
    |> live_step(user)
    |> wait_for_dashboard()
    |> assert_has(css("#dashboard-root"))

    assert %DateTime{} = Repo.get!(UserSchema, user.id).onboarding_completed_at

    assert %DateTime{} =
             Repo.get_by!(ProfileSchema, user_id: user.id).booking_link_first_shared_at

    assert [%{name: "Consultation", duration_minutes: 45}] =
             MeetingTypes.get_all_meeting_types(user.id)
  end

  # As sign-up leaves the account: the seeded meeting type and week, no link
  # of its own yet.
  defp new_host do
    user =
      insert(:user,
        onboarding_completed_at: nil,
        email: "e2e-onboard-#{System.unique_integer([:positive])}@example.com"
      )

    {:ok, _profile} = Profiles.create_profile(user.id)
    user
  end

  # Resized before the first page, so every page is laid out at this width.
  defp log_in(session, user, {width, height}) do
    session
    |> resize_window(width, height)
    |> visit("/auth/login")
    |> wait_for_live()
    |> fill_in(text_field("email"), with: user.email)
    |> fill_in(css("#password-input"), with: default_password())
    |> click(css("button[type='submit']"))
  end

  # Link: the suggested one is kept.
  defp link_step(session) do
    session
    |> assert_has(css("#onboarding-step-heading-profile"))
    |> wait_for_live()
    |> assert_has(css("#onboarding-stage"))
    |> assert_fits()
    |> click(css(@continue))
  end

  # Calendar: required, so Continue waits for one. Connecting it is the
  # inserted integration and a fresh visit, as the OAuth return is.
  defp calendar_step(session, user) do
    session
    |> assert_has(css("#onboarding-step-heading-connect_calendar"))
    |> assert_has(css("#onboarding-stage"))
    |> assert_has(css("#{@continue}[disabled]"))
    |> assert_fits()

    insert(:calendar_integration, user: user)

    session
    |> visit("/onboarding/connect_calendar")
    |> wait_for_live()
    |> assert_has(css(~s([data-week-state="ready"]), visible: :any))
    |> click(css("#{@continue}:not([disabled])"))
  end

  defp meeting_step(session) do
    session
    |> assert_has(css("#onboarding-step-heading-meeting"))
    |> assert_fits()
    |> fill_in(css("#meeting-name"), with: "Consultation")
    # Typed, not chosen: the matching chip lights once the server has the
    # name, and leaving the field saves it.
    |> assert_has(css(~s(#meeting-name-suggestions-1[aria-pressed="true"])))
    |> send_keys([:tab])
    |> press("#meeting-duration-45")
    |> assert_has(css(~s(#meeting-duration-45[aria-pressed="true"])))
    |> press("#meeting-location-video")
    |> assert_has(css(~s(#meeting-location-video[aria-pressed="true"])))
    |> press("#meeting-hours-preset-mornings")
    |> assert_has(css(~s(#meeting-hours-preset-mornings[aria-pressed="true"])))
    |> click(css(@continue))
  end

  # Look: a theme other than the one already chosen.
  defp look_step(session) do
    session
    |> assert_has(css("#onboarding-step-heading-choose_theme"))
    |> assert_fits()
    |> press(~s(button[data-testid="theme-thumbnail"][aria-pressed="false"]))
    |> assert_has(css(~s(button[data-testid="theme-thumbnail"][aria-pressed="true"])))
    |> click(css(@continue))
  end

  # Live: Go to dashboard does nothing until the link is kept with Copy link.
  defp live_step(session, user) do
    session =
      session
      |> assert_has(css("#onboarding-step-heading-ready"))
      |> assert_has(css("#onboarding-stage"))
      |> assert_has(css(~s(#onboarding-finish[aria-disabled="true"])))
      |> assert_fits()
      |> press("#onboarding-finish")
      |> assert_has(css("#onboarding-finish-helper", text: "Send or keep your link first"))
      |> assert_has(css("#onboarding-step-heading-ready"))

    assert Repo.get!(UserSchema, user.id).onboarding_completed_at == nil

    session
    |> press("#onboarding-keep-copy:not([disabled])")
    |> assert_has(css("#onboarding-finish:not([aria-disabled])"))
    |> press("#onboarding-finish")
  end

  # Read where the page has settled: the step's slide-in has run by the time
  # its heading is found.
  defp assert_fits(session) do
    session = execute_script(session, @layout_js, [], &send(self(), {:layout, &1}))
    assert_received {:layout, layout}

    assert layout["way_in_view"], "the way on is off screen"

    if layout["desktop"] do
      assert layout["height"] >= 860, "the page is #{layout["height"]}px tall, too short to judge"

      assert layout["column_overflow"] <= 1,
             "the question column scrolls by #{layout["column_overflow"]}px"
    end

    session
  end

  # A phone shows the step under the stage and above a pinned Continue bar,
  # so a control is scrolled to the middle of the screen first, as a thumb
  # would, for the press to reach it rather than the bar.
  defp press(session, selector) do
    session
    |> execute_script(
      "document.querySelector(arguments[0]).scrollIntoView({block: 'center'})",
      [selector]
    )
    |> click(css(selector, at: 0))
  end
end
