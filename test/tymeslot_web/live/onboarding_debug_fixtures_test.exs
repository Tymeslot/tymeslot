defmodule TymeslotWeb.OnboardingDebugFixturesTest do
  @moduledoc """
  The onboarding debug fixtures. The debug routes are mounted only when
  `:dev_routes` is on, which it is not in the test environment, so the
  fixtures are exercised directly on a socket.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :onboarding

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Availability.WeekPreview
  alias Tymeslot.Clock
  alias TymeslotWeb.OnboardingLive
  alias TymeslotWeb.OnboardingLive.DebugFixtures
  alias TymeslotWeb.OnboardingLive.LivePreview

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

  # The disconnected render is where the landing step is chosen, so the
  # handler is driven on it. Only `calendar` makes the page bookable, and only
  # the debug route lets a host who has not confirmed the meeting past it.
  test "debug fixture calendar shows the theme step" do
    user = insert(:user, onboarding_completed_at: nil)
    profile = insert(:profile, user: user, username: "debughost")

    socket =
      DebugFixtures.apply(
        %Socket{
          assigns: %{
            __changed__: %{},
            flash: %{},
            current_user: user,
            connected_calendars: [],
            booking_page_live: false,
            profile: profile,
            reveal_key: 0,
            patched_step: nil,
            live_action: :debug_step
          }
        },
        "calendar"
      )

    assert [%{provider: "google", provider_account_email: email}] =
             socket.assigns.connected_calendars

    assert email == user.email

    assert {:noreply, landed} =
             OnboardingLive.handle_params(
               %{"step" => "choose_theme"},
               "http://localhost:4000/dev/onboarding/choose_theme",
               socket
             )

    assert landed.assigns.current_step == :choose_theme
  end

  test "an unknown or not yet built fixture leaves the socket unchanged" do
    for name <- [nil, "nonsense"] do
      assert DebugFixtures.apply(socket(), name) == socket()
    end
  end

  test "kept marks the link as kept by copying" do
    assert DebugFixtures.apply(socket(), "kept").assigns.kept_method == "copy"
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
