defmodule TymeslotWeb.E2E.EmbedQuillPopupScheduleTest do
  @moduledoc """
  Guards Quill's schedule step in a popup embed without a layout, whose
  frame `embed.js` caps at 640px wide and at the host's viewport height.

  At that width the slot list stacks under the calendar, so the page is
  taller than the frame. Next Step used to be the last thing on it, below
  the fold, and the calendar and slot regions stayed scroll containers that
  held a wheel or touch scroll starting over them, so the frame did not
  move. Now the actions stay pinned to the frame's bottom edge and the frame
  is the only scroller.

  The page is marked embedded with `BookerSteps.mark_embedded/1`, as
  `EmbedSizesMatrixTest` does; the browser window stands in for the frame.
  """
  use TymeslotWeb.BrowserCase, async: false

  import TymeslotWeb.E2E.BookerSteps

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

  @moduletag :e2e
  @moduletag :scheduling

  @quill_theme_id "1"

  feature "embedded quill keeps next step in the frame and scrolls only the frame",
          %{session: session} do
    profile = create_user_with_meeting_type()

    session =
      session
      |> resize_window(640, 600)
      |> visit("/#{profile.username}?theme=#{@quill_theme_id}")
      |> wait_for_live()
      |> advance_to_schedule()
      |> mark_embedded()
      |> assert_has(css("[data-testid='time-slot']", minimum: 1))
      # Brought into sight as a visitor would. chromedriver's own scroll stops
      # with a time at the bottom edge, ignoring scroll-padding, where the
      # pinned actions take its click. Instant, since smooth scrolling would
      # still be moving (BookerSteps.click_next_step/1).
      |> execute_script("""
      document.documentElement.style.scrollBehavior = 'auto';
      document.querySelector("[data-testid='time-slot']").scrollIntoView({block: 'center'});
      """)
      |> pick_first("[data-testid='time-slot']")
      |> assert_has(css("[data-testid='next-step']:not([disabled])"))
      |> execute_script("window.scrollTo(0, 0);")

    layout =
      evaluate_script(session, """
      const next = document.querySelector("[data-testid='next-step']").getBoundingClientRect();
      const card = document.querySelector('.calendar-card');
      const scrollers = [card, ...card.querySelectorAll('*')]
        .filter((el) => ['auto', 'scroll'].includes(getComputedStyle(el).overflowY))
        .map((el) => el.className.toString());
      return {
        page: document.documentElement.scrollHeight,
        frame: window.innerHeight,
        next_top: next.top,
        next_bottom: next.bottom,
        scrollers: scrollers
      };
      """)

    # The page must outgrow the frame, or Next would be in view regardless.
    assert layout["page"] > layout["frame"]
    assert layout["next_top"] >= 0
    assert layout["next_bottom"] <= layout["frame"]
    assert layout["scrollers"] == []
  end

  defp create_user_with_meeting_type do
    user = create_onboarded_user()
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, _meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Popup Schedule Meeting",
        duration_minutes: 30,
        is_active: true
      })

    Profiles.get_profile(user.id)
  end
end
