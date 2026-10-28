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

  import TymeslotWeb.E2E.BookerLayoutAssertions
  import TymeslotWeb.E2E.BookerSteps

  alias Ecto.Changeset
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias TymeslotWeb.ThemeTestMatrix

  @moduletag :e2e
  @moduletag :scheduling

  @widths [320, 480, 640, 860, 1280]
  @height 800

  # Short viewports where the schedule step used to overflow its card and overlap
  # the action buttons. Includes the common laptop-height band (~660-820px inner
  # height: 1366x768 / 1536x864 screens, dragged-short windows) and extreme
  # landscape. Quill now bounds its schedule card to the viewport and scrolls the
  # calendar internally, so the Back/Next actions stay on-screen at all of these.
  @short_sizes [{1280, 360}, {1024, 400}, {812, 375}, {1280, 700}, {1440, 820}, {1366, 660}]

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

  feature "overview + schedule fit without horizontal overflow in both themes",
          %{session: session} do
    {profile, _slug} = create_user_with_meeting_type()

    for theme <- ThemeTestMatrix.all(), width <- @widths, reduce: session do
      acc ->
        acc
        |> resize_window(width, @height)
        |> visit("/#{profile.username}?theme=#{theme.id}")
        |> wait_for_live()
        |> assert_no_horizontal_overflow("#{theme.name} overview width=#{width}px")
        |> advance_to_schedule()
        |> assert_no_horizontal_overflow("#{theme.name} schedule width=#{width}px")
    end
  end

  feature "length step fits without horizontal overflow in both themes",
          %{session: session} do
    # A type offering several lengths asks for one between the overview and
    # the schedule, a step with a layout of its own.
    # The onboarded organiser has types of their own, so the one with several
    # lengths is picked by its slug rather than as the first card.
    {profile, slug} = create_user_with_several_lengths()

    for theme <- ThemeTestMatrix.all(), width <- @widths, reduce: session do
      acc ->
        acc
        |> resize_window(width, @height)
        |> visit("/#{profile.username}?theme=#{theme.id}")
        |> wait_for_live()
        |> pick_first("[data-testid='duration-option'][data-duration='#{slug}']")
        |> assert_has(css("[data-testid='next-step']:not([disabled])"))
        |> click_next_step()
        |> assert_has(css("[data-testid='length-step']"))
        |> assert_has(css("[data-testid='length-option']", count: 3))
        |> assert_no_horizontal_overflow("#{theme.name} length width=#{width}px")
    end
  end

  feature "length step keeps its actions reachable on wide-short viewports (both themes)",
          %{session: session} do
    {profile, slug} = create_user_with_several_lengths()

    for theme <- ThemeTestMatrix.all(), {width, height} <- @short_sizes, reduce: session do
      acc ->
        context = "#{theme.name} length #{width}x#{height}"

        acc
        |> resize_window(width, height)
        |> visit("/#{profile.username}/#{slug}?theme=#{theme.id}")
        |> wait_for_live()
        |> assert_has(css("[data-testid='length-step']"))
        |> assert_no_horizontal_overflow(context)
        |> assert_cta_reachable(context)
    end
  end

  feature "overview stays operable with introductory text at its length caps (both themes)",
          %{session: session} do
    # An organiser may fill the heading and both welcome lines to the character
    # limit the changeset allows. The caps were chosen so that the tallest legal
    # introduction still leaves the primary action reachable on the shortest
    # viewport the booker supports; this is what holds them to that.
    {profile, _slug} = create_user_with_max_length_booking_text()

    for theme <- ThemeTestMatrix.all(), {width, height} <- @short_sizes, reduce: session do
      acc ->
        context = "#{theme.name} overview max text #{width}x#{height}"

        acc
        |> resize_window(width, height)
        |> visit("/#{profile.username}?theme=#{theme.id}")
        |> wait_for_live()
        |> assert_no_horizontal_overflow(context)
        |> assert_cta_reachable(context)
    end
  end

  feature "schedule actions never overlap the calendar on wide-short viewports (both themes)",
          %{session: session} do
    {profile, slug} = create_user_with_meeting_type()

    for theme <- ThemeTestMatrix.all(), {width, height} <- @short_sizes, reduce: session do
      acc ->
        context = "#{theme.name} schedule #{width}x#{height}"

        acc
        |> resize_window(width, height)
        |> visit("/#{profile.username}/#{slug}?theme=#{theme.id}")
        |> wait_for_live()
        |> assert_has(css("[data-testid='schedule-actions']"))
        |> assert_no_horizontal_overflow(context)
        |> assert_no_actions_calendar_overlap(context)
        |> assert_cta_reachable(context)
    end
  end

  feature "schedule pins the actions row inside the viewport at short heights (app-shell themes)",
          %{session: session} do
    # A viewport-locked schedule step (app shell): the calendar's internal
    # scroll is the single scroll region, and the header + actions are pinned.
    # So at every short height, down to extreme landscape, the actions row
    # stays fully on-screen, not merely reachable by scrolling.
    {profile, slug} = create_user_with_meeting_type()
    themes = Enum.filter(ThemeTestMatrix.all(), & &1.pins_schedule_actions)
    assert themes != []

    for theme <- themes, {width, height} <- @short_sizes, reduce: session do
      acc ->
        context = "#{theme.name} schedule #{width}x#{height}"

        acc
        |> resize_window(width, height)
        |> visit("/#{profile.username}/#{slug}?theme=#{theme.id}")
        |> wait_for_live()
        |> assert_has(css("[data-testid='schedule-actions']"))
        |> assert_actions_within_viewport(context)
        |> assert_no_vertical_page_scroll(context)
    end
  end

  feature "embedded schedule flows to its natural height instead of the viewport's (both themes)",
          %{session: session} do
    # In an embed the viewport is the iframe, which iframe_embed.js sizes from
    # the content. A schedule step locked to the viewport would measure the
    # previous step's height and keep it, hiding the slots in a squeezed inner
    # scroll. `data-embedded` on a top-level page exercises the same rules, as
    # EmbedConfirmationLayoutTest does; the short window stands in for an
    # iframe still at the overview's height.
    {profile, _slug} = create_user_with_meeting_type()

    for theme <- ThemeTestMatrix.all(), width <- [480, 1280], reduce: session do
      acc ->
        context = "#{theme.name} embedded schedule #{width}x463"

        acc
        |> resize_window(width, 463)
        |> visit("/#{profile.username}?theme=#{theme.id}")
        |> wait_for_live()
        |> mark_embedded()
        |> advance_to_schedule()
        |> pick_first_visible_day()
        |> assert_has(css("[data-testid='time-slot']", minimum: 1))
        |> assert_no_inner_scroll_region(context)
    end
  end

  feature "a fixed-date type's dates scroll with the calendar at short heights (both themes)",
          %{session: session} do
    # The list of dates sits above the calendar. Were the calendar the only
    # scroll region, a long list would keep its height and squeeze the
    # calendar to nothing between the header and the actions.
    {profile, slug} = create_user_with_fixed_date_sessions(8)

    for theme <- ThemeTestMatrix.all(), {width, height} <- @short_sizes, reduce: session do
      acc ->
        context = "#{theme.name} fixed-date schedule #{width}x#{height}"

        acc
        |> resize_window(width, height)
        |> visit("/#{profile.username}/#{slug}?theme=#{theme.id}")
        |> wait_for_live()
        |> assert_has(css("[data-testid='session-list']"))
        |> assert_has(css("[data-testid='schedule-actions']"))
        |> assert_no_horizontal_overflow(context)
        |> assert_calendar_scrolls_with_session_list(context)
        |> assert_cta_reachable(context)
        |> then(fn acc ->
          if theme.pins_schedule_actions do
            acc
            |> assert_actions_within_viewport(context)
            |> assert_no_vertical_page_scroll(context)
          else
            acc
          end
        end)
    end
  end

  feature "branding banner stays within the viewport when the page content fits",
          %{session: session} do
    # Inject a stand-in for the SaaS branding banner via the theme-extensions
    # bridge (Core can't load the SaaS branding CSS). The banner sits in the
    # theme grid's footer row; without the `:has(.branding-footer)` rule the
    # content area's 10vh centering padding pushes it past 100vh.
    previous = Application.get_env(:tymeslot, :theme_extensions, [])

    Application.put_env(:tymeslot, :theme_extensions, [
      {TymeslotWeb.Test.BrandingFooterStub, :banner}
    ])

    on_exit(fn -> Application.put_env(:tymeslot, :theme_extensions, previous) end)

    {profile, slug} = create_user_with_meeting_type()

    # A viewport tall enough that the schedule comfortably fits — so the banner
    # only overflows if the `content-area` centering padding double-counts (the
    # bug). Below ~900px the schedule itself fills the viewport and the banner
    # legitimately sits below the fold, which wouldn't isolate the padding bug.
    session
    |> resize_window(1280, 1100)
    |> visit("/#{profile.username}/#{slug}")
    |> wait_for_live()
    |> assert_has(css(".branding-footer"))
    |> assert_no_horizontal_overflow("quill schedule with branding banner")
    |> assert_branding_footer_within_viewport("quill schedule with banner")
  end

  feature "custom-questions yes/no tiles render at 320px without overflow",
          %{session: session} do
    {profile, slug} = create_user_with_yes_no_question()

    session
    |> resize_window(640, @height)
    |> visit("/#{profile.username}/#{slug}")
    |> wait_for_live()
    |> pick_first_slot()
    |> assert_has(css(".custom-question-yes-no"))
    |> resize_window(320, @height)
    |> assert_has(css(".custom-question-yes-no-tile.is-yes"))
    |> assert_has(css(".custom-question-yes-no-tile.is-no"))
    |> assert_no_horizontal_overflow("custom-questions yes/no width=320px")
  end

  feature "booking form name+email stack vertically at 320px", %{session: session} do
    {profile, slug} = create_user_with_meeting_type()

    session
    |> resize_window(640, @height)
    |> visit("/#{profile.username}/#{slug}")
    |> wait_for_live()
    |> pick_first_slot()
    |> assert_has(css("[data-testid='booking-form']"))
    |> resize_window(320, @height)
    |> assert_no_horizontal_overflow("booking form width=320px")
    |> assert_name_email_stacked("booking form width=320px")
  end

  # ── Setup helpers ──────────────────────────────────────────────────────

  defp create_user_with_max_length_booking_text do
    {profile, slug} = create_user_with_meeting_type()

    profile =
      profile
      |> Changeset.change(%{
        booking_text_enabled: true,
        booking_heading: String.duplicate("Wo", 30),
        booking_greeting: String.duplicate("Wo", 40),
        booking_instruction: String.duplicate("Wo", 40)
      })
      |> Repo.update!()

    {profile, slug}
  end

  defp create_user_with_meeting_type(attrs \\ %{}) do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, meeting_type} =
      %{
        user_id: user.id,
        name: "Sizes Matrix Meeting",
        duration_minutes: 30,
        is_active: true
      }
      |> Map.merge(attrs)
      |> MeetingTypes.create_meeting_type()

    {profile, Slugs.to_slug(meeting_type)}
  end

  defp create_user_with_several_lengths,
    do: create_user_with_meeting_type(%{extra_lengths_minutes: [60, 15]})

  # A fixed-date group type held at one venue, with `count` sessions planned
  # two days apart from tomorrow.
  defp create_user_with_fixed_date_sessions(count) do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)
    insert(:calendar_integration, user_id: user.id, user: user)
    venue = insert(:venue, user: user, name: "Main Hall")

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Sizes Matrix Workshop",
        duration_minutes: 90,
        is_active: true,
        max_participants: 12,
        fixed_dates: true,
        locations: [in_person_location([venue])]
      )

    for day <- 1..count do
      starts_at = Date.utc_today() |> Date.add(day * 2) |> DateTime.new!(~T[16:00:00], "Etc/UTC")
      {:ok, _session} = PlannedSessions.add(meeting_type, meeting_type.user_id, starts_at)
    end

    {profile, Slugs.to_slug(meeting_type)}
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

    {profile, Slugs.to_slug(meeting_type)}
  end
end
