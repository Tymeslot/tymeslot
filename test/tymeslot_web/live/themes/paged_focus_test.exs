defmodule TymeslotWeb.Live.Themes.PagedFocusTest do
  @moduledoc """
  The keyboard focus on every shipped theme that shows one moment at a time
  (`Navigators.Paged`): the visitor's own move to another moment, forward by
  choosing a meeting type, a length or by Next, or back by Back or the step
  indicator, sends the focus to the arriving moment's heading
  (`:journey_focus`, taken by the heading's `phx-mounted` through
  `Journey.Components.moment_heading/1`); the page a visit lands on never
  takes it.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :bookings
  @moduletag :live

  import Mox
  import Tymeslot.JourneyFixtureHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged
  alias TymeslotWeb.Themes.Shared.Journey.Progress
  alias TymeslotWeb.ThemeTestMatrix

  # Every shipped theme on the paged navigator, read from its journey, so a
  # theme moving to another navigator leaves this suite by itself.
  @paged (for theme <- ThemeTestMatrix.all(),
              ThemeInfo.get_live_view_module(theme.id).__journey__().navigator == Paged do
            theme
          end)

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

  # A guard against the suite thinning out unnoticed: a theme leaving the
  # paged navigator, or one joining it, is a change this list must follow.
  test "the paged themes are the ones this suite means" do
    paged =
      for theme <- ThemeTestMatrix.all(),
          ThemeInfo.get_live_view_module(theme.id).__journey__().navigator == Paged,
          do: theme.key

    assert paged == [:quill, :rhythm, :paper]
    assert Enum.map(@paged, & &1.key) == paged
  end

  for theme <- @paged do
    describe "#{theme.name}" do
      @theme theme

      test "the page a visit lands on takes no focus", %{conn: conn} do
        %{profile: profile} = seed_organiser(@theme.id, "focus-load-#{@theme.slug}")

        {:ok, view, _html} = live(conn, "/#{profile.username}")
        %{offer: overview} = moments(view)

        assert has_element?(view, "##{overview}-heading-current")
        refute has_element?(view, "##{overview}-heading-current[phx-mounted]")
        assert live_assigns(view)[:journey_focus] == nil

        {:ok, view, _html} = live(conn, "/#{profile.username}/quick-chat")
        %{slot: schedule} = moments(view)

        assert has_element?(view, "##{schedule}-heading-current")
        refute has_element?(view, "##{schedule}-heading-current[phx-mounted]")
        assert live_assigns(view)[:journey_focus] == nil
      end

      test "choosing a meeting type, then a time, moves the focus on", %{conn: conn} do
        %{profile: profile} = seed_organiser(@theme.id, "focus-on-#{@theme.slug}")
        {:ok, view, _html} = live(conn, "/#{profile.username}")

        BookingDriver.choose_meeting_type(view, "quick-chat")
        %{slot: schedule, attendee: attendee} = moments(view)

        assert live_assigns(view).journey_focus == schedule
        assert has_element?(view, "##{schedule}-heading-current[phx-mounted]")

        BookingDriver.pick_first_slot(view)

        case attendee do
          # One screen picks the time and asks the details (Paper): the
          # moment stays, and the details part's heading takes the focus.
          ^schedule ->
            assert live_assigns(view).journey_focus == schedule
            assert has_element?(view, "[id^='paper-book-head-'][phx-mounted]")

          details ->
            BookingDriver.continue(view)

            assert live_assigns(view).journey_focus == details
            assert has_element?(view, "##{details}-heading-current[phx-mounted]")
        end
      end

      test "the length step takes the focus, and hands it on", %{conn: conn} do
        %{profile: profile} =
          seed_organiser(@theme.id, "focus-len-#{@theme.slug}",
            types: [[name: "Quick Chat", duration_minutes: 30, extra_lengths_minutes: [60]]]
          )

        {:ok, view, _html} = live(conn, "/#{profile.username}")

        BookingDriver.choose_meeting_type(view, "quick-chat")

        assert live_assigns(view).current_state == :length
        assert live_assigns(view).journey_focus == :length
        assert has_element?(view, "#length-heading-current[phx-mounted]")

        BookingDriver.choose_length(view, 60)
        BookingDriver.continue(view)
        %{slot: schedule} = moments(view)

        assert live_assigns(view).journey_focus == schedule
        assert has_element?(view, "##{schedule}-heading-current[phx-mounted]")
      end

      test "Back moves the focus to the moment it returns to", %{conn: conn} do
        %{profile: profile} = seed_organiser(@theme.id, "focus-back-#{@theme.slug}")
        {:ok, view, _html} = live(conn, "/#{profile.username}")
        %{offer: overview} = moments(view)

        BookingDriver.choose_meeting_type(view, "quick-chat")
        refute live_assigns(view).journey_focus == overview

        BookingDriver.back(view)

        assert live_assigns(view).current_state == overview
        assert live_assigns(view).journey_focus == overview
        assert has_element?(view, "##{overview}-heading-current[phx-mounted]")
      end

      test "the step indicator moves the focus to the step it returns to", %{conn: conn} do
        %{profile: profile} = seed_organiser(@theme.id, "focus-step-#{@theme.slug}")
        {:ok, view, _html} = live(conn, "/#{profile.username}")
        %{offer: overview} = moments(view)

        BookingDriver.choose_meeting_type(view, "quick-chat")
        refute live_assigns(view).journey_focus == overview

        render_hook(view, "navigate_to_step", %{"step" => "1"})

        assert live_assigns(view).current_state == overview
        assert live_assigns(view).journey_focus == overview
        assert has_element?(view, "##{overview}-heading-current[phx-mounted]")
      end
    end
  end

  # The moments collecting the meeting type, the slot and the attendee.
  defp moments(view) do
    journey = live_assigns(view).journey

    %{
      offer: Progress.moment_for(journey, :meeting_type),
      slot: Progress.moment_for(journey, :slot),
      attendee: Progress.moment_for(journey, :attendee)
    }
  end
end
