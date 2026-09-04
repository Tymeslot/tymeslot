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

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Wallaby.Element

  @moduletag :e2e
  @moduletag :scheduling

  @widths [320, 480, 640, 860, 1280]
  @height 800

  # Sub-pixel rounding in the WebDriver bridge can show a measurement one px
  # over the viewport even when the element fits. Shared with the
  # `assert_no_horizontal_overflow/2` in `E2EHelpers`, which carries its own
  # copy: the tolerance is a property of the bridge, not of either module.
  @overflow_tolerance 1

  # Both shipping themes, overridden at view time via `?theme=`.
  @themes [{"1", "Quill"}, {"2", "Rhythm"}]

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

    for {theme_id, theme_name} <- @themes, width <- @widths, reduce: session do
      acc ->
        acc
        |> resize_window(width, @height)
        |> visit("/#{profile.username}?theme=#{theme_id}")
        |> wait_for_live()
        |> assert_no_horizontal_overflow("#{theme_name} overview width=#{width}px")
        |> advance_to_schedule()
        |> assert_no_horizontal_overflow("#{theme_name} schedule width=#{width}px")
    end
  end

  feature "overview stays operable with introductory text at its length caps (both themes)",
          %{session: session} do
    # An organiser may fill the heading and both welcome lines to the character
    # limit the changeset allows. The caps were chosen so that the tallest legal
    # introduction still leaves the primary action reachable on the shortest
    # viewport the booker supports; this is what holds them to that.
    {profile, _slug} = create_user_with_max_length_booking_text()

    for {theme_id, theme_name} <- @themes, {width, height} <- @short_sizes, reduce: session do
      acc ->
        context = "#{theme_name} overview max text #{width}x#{height}"

        acc
        |> resize_window(width, height)
        |> visit("/#{profile.username}?theme=#{theme_id}")
        |> wait_for_live()
        |> assert_no_horizontal_overflow(context)
        |> assert_cta_reachable(context)
    end
  end

  feature "schedule actions never overlap the calendar on wide-short viewports (both themes)",
          %{session: session} do
    {profile, slug} = create_user_with_meeting_type()

    for {theme_id, theme_name} <- @themes, {width, height} <- @short_sizes, reduce: session do
      acc ->
        context = "#{theme_name} schedule #{width}x#{height}"

        acc
        |> resize_window(width, height)
        |> visit("/#{profile.username}/#{slug}?theme=#{theme_id}")
        |> wait_for_live()
        |> assert_has(css("[data-testid='schedule-actions']"))
        |> assert_no_horizontal_overflow(context)
        |> assert_no_actions_calendar_overlap(context)
        |> assert_cta_reachable(context)
    end
  end

  feature "Quill schedule pins the actions row inside the viewport at short heights",
          %{session: session} do
    # Quill viewport-locks the schedule step (app-shell): the calendar's internal
    # scroll is the single scroll region, and the header + actions are pinned. So
    # at every short height — down to extreme landscape — the actions row stays
    # fully on-screen, not merely reachable by scrolling.
    {profile, slug} = create_user_with_meeting_type()

    for {width, height} <- @short_sizes, reduce: session do
      acc ->
        context = "Quill schedule #{width}x#{height}"

        acc
        |> resize_window(width, height)
        |> visit("/#{profile.username}/#{slug}?theme=1")
        |> wait_for_live()
        |> assert_has(css("[data-testid='schedule-actions']"))
        |> assert_actions_within_viewport(context)
        |> assert_no_vertical_page_scroll(context)
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

  # Walks the overview → schedule journey: pick the meeting type, then Next.
  #
  # This is the only entry path that renders the Back button, and so the only one
  # that produces the full two-button actions row: a direct booking link sets
  # `entered_via_overview: false`, because there is no overview to go back to.
  # It is also the journey an embedded booker actually takes.
  #
  # The short-viewport features deliberately deep-link instead. Below roughly
  # 250px of usable height the overview's own CTA sits past the end of a page
  # that doesn't scroll, so it can't be clicked — a limit of the overview, not of
  # the schedule layout those features guard.
  defp advance_to_schedule(session) do
    session
    |> pick_first_duration()
    # Both themes disable Next until the selected duration round-trips to the
    # server. Clicking it before then is a no-op, so wait for it to enable.
    |> assert_has(css("[data-testid='next-step']:not([disabled])"))
    |> click_next_step()
    |> assert_has(css("[data-testid='back-step']"))
  end

  defp pick_first_duration(session) do
    session
    |> find(css("[data-testid='duration-option']", count: :any))
    |> List.first()
    |> Element.click()

    session
  end

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

  # Stronger than assert_cta_reachable: on Quill's bounded-card model the pinned
  # actions must sit fully inside the viewport at short heights — proving the
  # calendar scrolls internally rather than pushing the buttons off-screen.
  #
  # Measures the actions row rather than the individual buttons: Back only exists
  # when the booker came via the overview, but the row it lives in is what has to
  # stay pinned, and both buttons share its vertical extent.
  defp assert_actions_within_viewport(session, context) do
    me = self()
    ref = make_ref()

    execute_script(
      session,
      """
      const actions = document.querySelector("[data-testid='schedule-actions']");
      if (!actions) return null;
      const a = actions.getBoundingClientRect();
      return [Math.round(a.top), Math.round(a.bottom), window.innerHeight];
      """,
      fn value -> send(me, {:actions, ref, value}) end
    )

    assert_receive {:actions, ^ref, value}, 5_000
    assert is_list(value), "schedule actions not found at #{context}"
    [top, bottom, inner_h] = value

    assert top >= -@overflow_tolerance and bottom <= inner_h + @overflow_tolerance,
           "The schedule actions row is outside the viewport at #{context} " <>
             "(top=#{top}, bottom=#{bottom}, viewport=#{inner_h}) — the bounded " <>
             "schedule card should keep it pinned on-screen."

    session
  end

  # Regression guard for the "double overflow": the viewport-locked schedule step
  # must scroll only inside the calendar — never the page on top of it. Asserts the
  # document doesn't exceed the viewport height (a few px of WebDriver rounding
  # tolerated).
  defp assert_no_vertical_page_scroll(session, context) do
    me = self()
    ref = make_ref()

    execute_script(
      session,
      "return [document.documentElement.scrollHeight, window.innerHeight];",
      fn [scroll_height, inner_height] ->
        send(me, {:vscroll, ref, scroll_height, inner_height})
      end
    )

    assert_receive {:vscroll, ^ref, scroll_height, inner_height}, 5_000

    assert scroll_height <= inner_height + 2,
           """
           Page scrolls vertically at #{context} (double overflow):
             document scrollHeight = #{scroll_height}px
             viewport innerHeight  = #{inner_height}px
           The schedule step should lock to the viewport and scroll only inside
           the calendar.
           """

    session
  end

  # Guards the wide-short schedule fix: the layout must not let the calendar
  # overflow its card and paint over the actions row.
  defp assert_no_actions_calendar_overlap(session, context) do
    me = self()
    ref = make_ref()

    execute_script(
      session,
      """
      const actions = document.querySelector("[data-testid='schedule-actions']");
      const day = document.querySelector("[data-testid='calendar-day']");
      if (!actions || !day) return null;
      const a = actions.getBoundingClientRect(), c = day.getBoundingClientRect();
      // overlap iff the rects intersect on both axes
      return !(a.right <= c.left || a.left >= c.right || a.bottom <= c.top || a.top >= c.bottom);
      """,
      fn value -> send(me, {:overlap, ref, value}) end
    )

    assert_receive {:overlap, ^ref, overlap}, 5_000

    refute overlap,
           "The schedule actions row overlaps the calendar at #{context} — the " <>
             "schedule card is clipping/overflowing instead of growing to its " <>
             "natural height."

    session
  end

  # The primary CTA must live inside the scrollable page (reachable by scrolling),
  # not be clipped beyond the document's scroll height.
  defp assert_cta_reachable(session, context) do
    me = self()
    ref = make_ref()

    execute_script(
      session,
      """
      const cta = document.querySelector("[data-testid='next-step']");
      if (!cta) return null;
      const r = cta.getBoundingClientRect();
      return [Math.round(r.bottom + window.scrollY), r.height, document.documentElement.scrollHeight];
      """,
      fn value -> send(me, {:cta, ref, value}) end
    )

    assert_receive {:cta, ^ref, value}, 5_000

    assert is_list(value), "next-step CTA not found at #{context}"
    [cta_doc_bottom, cta_height, scroll_height] = value

    assert cta_height > 0, "next-step CTA has zero height at #{context}"

    assert cta_doc_bottom <= scroll_height + @overflow_tolerance,
           "next-step CTA at #{context} sits below the document scroll height " <>
             "(#{cta_doc_bottom}px > #{scroll_height}px) — it is clipped and unreachable."

    session
  end

  # On a page whose booking content fits the viewport, the branding banner must
  # sit inside the viewport (its bottom within innerHeight), not be pushed past
  # 100vh by the content area's centering padding.
  defp assert_branding_footer_within_viewport(session, context) do
    me = self()
    ref = make_ref()

    execute_script(
      session,
      """
      const f = document.querySelector('.branding-footer');
      if (!f) return null;
      return [Math.round(f.getBoundingClientRect().bottom), window.innerHeight];
      """,
      fn value -> send(me, {:foot, ref, value}) end
    )

    assert_receive {:foot, ^ref, value}, 5_000

    assert is_list(value), "branding footer not found at #{context}"
    [foot_bottom, inner_h] = value

    assert foot_bottom <= inner_h + @overflow_tolerance,
           "Branding banner overflows the viewport at #{context}: banner bottom " <>
             "#{foot_bottom}px > viewport #{inner_h}px. Content fits, so the banner " <>
             "must share the viewport (see the :has(.branding-footer) rule)."

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
