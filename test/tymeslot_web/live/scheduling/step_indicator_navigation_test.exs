defmodule TymeslotWeb.Live.Scheduling.StepIndicatorNavigationTest do
  @moduledoc """
  The booking page's step indicator offers a step as clickable only when a
  click on it would move the booker (`Navigator.can_go_to?/3`, the rule
  `go_to/3` applies): on a direct or private link the overview is never
  offered, and on a flow that came through the overview it is, and moves
  there. Every shipped theme is walked; a theme that renders no indicator
  must offer no step either.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  @timezone "America/New_York"
  @duration "quick-chat"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    :ok
  end

  defp offered(step), do: "button[phx-click='navigate_to_step'][phx-value-step='#{step}']"

  # A theme that draws the step indicator marks each step's circle; one that
  # draws none must still offer no step.
  defp renders_indicator?(view), do: has_element?(view, ".step-item-wrapper .step-circle")

  for theme <- ThemeTestMatrix.all() do
    @theme theme

    describe "#{theme.name}" do
      setup do
        seed_booking_account(@theme.id, "steps-#{@theme.slug}", @timezone)
      end

      @tag :capture_log
      test "a direct link never offers the overview step", %{profile: profile} do
        {:ok, view, _html} =
          live(build_conn(), ~p"/#{profile.username}/#{@duration}?timezone=#{@timezone}")

        refute has_element?(view, offered(1))
        refute has_element?(view, ".step-circle--clickable")

        BookingDriver.pick_first_slot(view)
        BookingDriver.continue(view)
        assert has_element?(view, "form[phx-submit='submit']")

        refute has_element?(view, offered(1))

        if renders_indicator?(view) do
          # The schedule behind the form is still offered: only the overview
          # is refused.
          assert has_element?(view, offered(2))
          assert has_element?(view, "[aria-current='step']")
        end
      end

      if theme.id == "1" do
        @tag :capture_log
        test "through the overview, step 1 is offered and moves back to it", %{profile: profile} do
          {:ok, view, _html} = live(build_conn(), ~p"/#{profile.username}?timezone=#{@timezone}")

          BookingDriver.choose_meeting_type(view, @duration)
          BookingDriver.continue(view)

          assert renders_indicator?(view)
          refute has_element?(view, "[data-testid='duration-option']")

          view |> element(offered(1)) |> render_click()

          assert has_element?(view, "[data-testid='duration-option']")
        end
      end
    end
  end
end
