defmodule TymeslotWeb.E2E.OnboardingTest do
  @moduledoc """
  The five-step onboarding wizard in a real browser, at a desktop and a
  phone width: link, calendar, meeting, look, live, then the dashboard.

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

  setup do
    stub_free_calendar()
    :ok
  end

  feature "a new host walks the wizard to the dashboard at desktop width", %{session: session} do
    walk_the_wizard(session, {1280, 900})
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
    |> click(css(@continue))
  end

  # Calendar: required, so Continue waits for one. Connecting it is the
  # inserted integration and a fresh visit, as the OAuth return is.
  defp calendar_step(session, user) do
    session
    |> assert_has(css("#onboarding-step-heading-connect_calendar"))
    |> assert_has(css("#onboarding-stage"))
    |> assert_has(css("#{@continue}[disabled]"))

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

  # Look: a story other than the one already chosen.
  defp look_step(session) do
    session
    |> assert_has(css("#onboarding-step-heading-choose_theme"))
    |> press(~s(button[data-testid="theme-story"][aria-pressed="false"]))
    |> assert_has(css(~s(button[data-testid="theme-story"][aria-pressed="true"])))
    |> click(css(@continue))
  end

  # Live: Go to dashboard does nothing until the link is kept with Copy link.
  defp live_step(session, user) do
    session =
      session
      |> assert_has(css("#onboarding-step-heading-ready"))
      |> assert_has(css("#onboarding-stage"))
      |> assert_has(css(~s(#onboarding-finish[aria-disabled="true"])))
      |> press("#onboarding-finish")
      |> assert_has(css("#onboarding-finish-helper", text: "Send or keep your link first"))
      |> assert_has(css("#onboarding-step-heading-ready"))

    assert Repo.get!(UserSchema, user.id).onboarding_completed_at == nil

    session
    |> press("#onboarding-keep-copy:not([disabled])")
    |> assert_has(css("#onboarding-finish:not([aria-disabled])"))
    |> press("#onboarding-finish")
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
