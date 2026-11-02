defmodule TymeslotWeb.Live.Themes.RhythmSlidesTest do
  @moduledoc """
  Rhythm's steps slide in: every step after the overview draws its slide
  with the entrance class (`slide--enter`, `base.css`, `rhythm-slide-in`),
  inside a root whose id is the step's, so a step change inserts a new
  slide and its entrance plays. The overview, the page's first paint, does
  not slide in.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  test "the schedule slides in, the overview does not", %{conn: conn} do
    %{profile: profile} =
      seed_organiser("2", "rhythm-slides", types: [[name: "Quick Chat", duration_minutes: 30]])

    {:ok, view, _html} = live(conn, "/#{profile.username}")
    assert has_element?(view, "#overview-step .slide.active")
    refute has_element?(view, "#overview-step .slide--enter")

    BookingDriver.choose_meeting_type(view, "quick-chat")

    assert has_element?(view, "#schedule-step .slide.slide--enter.active")
    refute has_element?(view, "#overview-step")
  end
end
