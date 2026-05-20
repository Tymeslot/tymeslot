defmodule TymeslotWeb.E2E.EmbedSizesMatrixTest do
  @moduledoc """
  Guards the embed sizing contract: the booker must lay out without
  horizontal overflow at every promised iframe width.

  Covers the layout deliverables of:
    - Phase 2 (container queries on `.glass-morphism-card`)
    - Phase 3 (no Tailwind width caps inside scheduling components)

  Container queries fire on the booker's own card root regardless of whether
  the page is in an iframe — so resizing the browser viewport exercises the
  same layout code that embedded contexts hit, without the complexity of
  setting up `?embed=1` (signed token, allowed domains, parent-origin handshake).

  Also asserts two narrow-width behaviours that custom-question and
  booking-form layouts depend on:
    - Yes/No tiles render side-by-side without overflow at 320 px
    - Name + Email auto-stack vertically at 320 px
  """
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Wallaby.Element

  @moduletag :e2e
  @moduletag :scheduling

  @widths [320, 480, 640, 860, 1280]
  @height 800
  # Sub-pixel rounding in the WebDriver bridge can show scrollWidth one px
  # over innerWidth even when the page fits — tolerate that one px.
  @overflow_tolerance 1

  feature "overview step fits without horizontal overflow at every matrix size",
          %{session: session} do
    {profile, _slug} = create_user_with_meeting_type()

    Enum.reduce(@widths, session, fn width, acc ->
      acc
      |> resize_window(width, @height)
      |> visit("/#{profile.username}")
      |> wait_for_live()
      |> assert_has(css(".overview-content-area"))
      |> assert_no_horizontal_overflow("overview width=#{width}px")
    end)
  end

  feature "custom-questions yes/no tiles render at 320px without overflow",
          %{session: session} do
    {profile, slug} = create_user_with_yes_no_question()

    session
    |> resize_window(640, @height)
    |> visit("/#{profile.username}/#{slug}")
    |> wait_for_live()
    |> pick_first_calendar_day()
    |> pick_first_time_slot()
    |> click_next_step()
    |> assert_has(css(".custom-question-yes-no"))
    |> resize_window(320, @height)
    |> assert_has(css(".custom-question-yes-no-tile.is-yes"))
    |> assert_has(css(".custom-question-yes-no-tile.is-no"))
    |> assert_no_horizontal_overflow("custom-questions yes/no width=320px")
  end

  feature "booking form name+email stack vertically at 320px", %{session: session} do
    {profile, slug} = create_user_with_meeting_type()

    session =
      session
      |> resize_window(640, @height)
      |> visit("/#{profile.username}/#{slug}")
      |> wait_for_live()
      |> pick_first_calendar_day()
      |> pick_first_time_slot()
      |> click_next_step()
      |> assert_has(css("[data-testid='booking-form']"))
      |> resize_window(320, @height)
      |> assert_no_horizontal_overflow("booking form width=320px")

    assert_name_email_stacked(session)
  end

  # ── Setup helpers ──────────────────────────────────────────────────────

  defp create_user_with_meeting_type do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Sizes Matrix Meeting",
        duration_minutes: 30,
        is_active: true
      })

    {profile, MeetingTypes.to_slug(meeting_type)}
  end

  defp create_user_with_yes_no_question do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "With Yes/No Question",
        duration_minutes: 30,
        is_active: true,
        custom_fields: [
          %{
            type: "yes_no",
            label: "Are you an existing customer?",
            required: true,
            position: 0
          }
        ]
      })

    {profile, MeetingTypes.to_slug(meeting_type)}
  end

  # ── Navigation helpers ────────────────────────────────────────────────

  defp click_next_step(session) do
    click(session, css("[data-testid='next-step']"))
  end

  defp pick_first_calendar_day(session) do
    session
    |> find(css("[data-testid='calendar-day']:not([disabled])", count: :any))
    |> List.first()
    |> Element.click()

    session
  end

  defp pick_first_time_slot(session) do
    session = assert_has(session, css("[data-testid='time-slot']", minimum: 1))

    session
    |> find(css("[data-testid='time-slot']", count: :any))
    |> List.first()
    |> Element.click()

    session
  end

  # ── Layout assertions ─────────────────────────────────────────────────

  defp assert_no_horizontal_overflow(session, context) do
    me = self()
    ref = make_ref()

    session =
      execute_script(
        session,
        "return [document.documentElement.scrollWidth, window.innerWidth];",
        fn [scroll_width, inner_width] ->
          send(me, {:overflow, ref, scroll_width, inner_width})
        end
      )

    assert_receive {:overflow, ^ref, scroll_width, inner_width}, 5_000

    assert scroll_width <= inner_width + @overflow_tolerance,
           """
           Horizontal overflow at #{context}:
             scrollWidth = #{scroll_width}px
             innerWidth  = #{inner_width}px
           """

    session
  end

  defp assert_name_email_stacked(session) do
    me = self()
    ref = make_ref()

    execute_script(
      session,
      """
      const name = document.querySelector("input[name='booking[name]']");
      const email = document.querySelector("input[name='booking[email]']");
      if (!name || !email) return null;
      return [name.getBoundingClientRect().top, email.getBoundingClientRect().top];
      """,
      fn value -> send(me, {:positions, ref, value}) end
    )

    assert_receive {:positions, ^ref, positions}, 5_000

    assert is_list(positions),
           "Expected name + email bounding rects, got nil — fields not in DOM"

    [name_top, email_top] = positions

    assert email_top > name_top,
           "Name and email did not stack at 320px " <>
             "(name_top=#{name_top}, email_top=#{email_top}). " <>
             "`.booking-inline-fields` should collapse to one column."
  end
end
