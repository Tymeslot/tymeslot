defmodule TymeslotWeb.OnboardingDebugFixturesTest do
  @moduledoc """
  The onboarding debug fixtures. The debug routes are mounted only when
  `:dev_routes` is on, which it is not in the test environment, so the
  fixtures are exercised directly on a socket.
  """

  use ExUnit.Case, async: true
  @moduletag :onboarding

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Availability.WeekPreview
  alias Tymeslot.Clock
  alias TymeslotWeb.OnboardingLive.DebugFixtures
  alias TymeslotWeb.OnboardingLive.LivePreview
  alias TymeslotWeb.OnboardingLive.StepConfig

  defp socket do
    %Socket{
      assigns: %{
        __changed__: %{},
        current_user: %{email: "host@example.com"},
        connected_calendars: [],
        booking_page_live: false,
        profile: nil,
        reveal_key: 0
      }
    }
  end

  # Tuesday 3 November 2026, midday, so today is the Tuesday in any zone the
  # default timezone might be.
  defp freeze_clock, do: Process.put(Clock.process_key(), ~U[2026-11-03 12:00:00Z])

  test "debug fixture calendar shows the theme step" do
    socket = DebugFixtures.apply(socket(), "calendar")

    assert [%{provider: "google", provider_account_email: "host@example.com"}] =
             socket.assigns.connected_calendars

    assert socket.assigns.booking_page_live

    # A bookable calendar is what opens the steps past the calendar one.
    resume =
      StepConfig.resume_step(%{
        username: "host",
        bookable_calendar?: socket.assigns.booking_page_live
      })

    assert resume == :meeting
    assert StepConfig.reachable?(:choose_theme, resume)
  end

  test "an unknown or not yet built fixture leaves the socket unchanged" do
    for name <- [nil, "nonsense", "kept"] do
      assert DebugFixtures.apply(socket(), name) == socket()
    end
  end

  test "reveal_ready returns the fixed week" do
    freeze_clock()
    assigns = DebugFixtures.apply(socket(), "reveal_ready").assigns

    assert %{state: :ready, preview: %WeekPreview{} = preview} = assigns.stage_week
    assert preview.slot_count == 23
    assert preview.first_busy == %{date: ~D[2026-11-03], start: ~T[14:00:00]}

    assert %{busy: [{~T[10:00:00], ~T[11:30:00]}]} =
             Enum.find(preview.days, &(&1.date == ~D[2026-11-05]))

    assert [_calendar] = assigns.connected_calendars
    assert assigns.reveal_key == 1

    # The caption the stage shows, and the live region announces.
    assert LivePreview.week_caption(assigns.stage_week) ==
             "Your Tuesday 02:00 PM is already blocked. 23 open slots this week."
  end

  test "reveal_empty is the same week ready with no busy blocks" do
    freeze_clock()

    %{stage_week: week} = DebugFixtures.apply(socket(), "reveal_empty").assigns

    assert week.state == :ready
    assert week.preview.slot_count == 23
    assert week.preview.first_busy == nil
    assert Enum.all?(week.preview.days, &(&1.busy == []))
    assert LivePreview.week_caption(week) == "23 open slots this week."
  end

  test "reveal_slow and reveal_failed connect the calendar and caption nothing" do
    for {name, state} <- [{"reveal_slow", :slow}, {"reveal_failed", :failed}] do
      assigns = DebugFixtures.apply(socket(), name).assigns

      assert assigns.stage_week == %{state: state, preview: nil}
      assert [_calendar] = assigns.connected_calendars
      assert LivePreview.week_caption(assigns.stage_week) == nil
    end
  end
end
