defmodule TymeslotWeb.OnboardingDebugFixturesTest do
  @moduledoc """
  The onboarding debug fixtures. The debug routes are mounted only when
  `:dev_routes` is on, which it is not in the test environment, so the
  fixtures are exercised directly on a socket.
  """

  use ExUnit.Case, async: true
  @moduletag :onboarding

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.OnboardingLive.DebugFixtures
  alias TymeslotWeb.OnboardingLive.StepConfig

  defp socket do
    %Socket{
      assigns: %{
        __changed__: %{},
        current_user: %{email: "host@example.com"},
        connected_calendars: [],
        booking_page_live: false
      }
    }
  end

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
    for name <- [nil, "nonsense", "reveal_ready", "kept"] do
      assert DebugFixtures.apply(socket(), name) == socket()
    end
  end
end
