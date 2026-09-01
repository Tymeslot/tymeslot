defmodule TymeslotWeb.Live.Themes.ThemeBookingRaceTest do
  @moduledoc """
  Split out of `ThemeBookingFlowTest` to keep each module focused: the
  concurrent double-booking edge case, which drives two live sessions against
  the same slot.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :utils

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers

  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  describe "extra booking edge cases" do
    @tag :capture_log
    test "prevents double booking the same slot (race condition simulation)", %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, booking_theme: "1", username: "race-condition")
      _integration = insert(:calendar_integration, user: user, is_active: true)

      insert(:meeting_type, user: user, name: "30 Minutes", duration_minutes: 30, is_active: true)

      date = Date.to_string(next_business_day(Date.utc_today()))
      time = "10:00 AM"
      timezone = "America/New_York"

      # 1. Start first booking
      {:ok, view1, _html} =
        live(
          conn,
          ~p"/#{profile.username}/30-minutes/book?date=#{date}&time=#{time}&timezone=#{timezone}"
        )

      # 2. Start second booking (different attendee)
      {:ok, view2, _html} =
        live(
          conn,
          ~p"/#{profile.username}/30-minutes/book?date=#{date}&time=#{time}&timezone=#{timezone}"
        )

      # Submit first
      view1
      |> form("form[data-testid='booking-form']", %{
        "booking" => %{"name" => "First", "email" => "first@example.com"}
      })
      |> render_submit()

      wait_until(fn -> has_element?(view1, "[data-testid='confirmation-heading']") end)

      # Submit second for the same slot
      view2
      |> form("form[data-testid='booking-form']", %{
        "booking" => %{"name" => "Second", "email" => "second@example.com"}
      })
      |> render_submit()

      # The flash is delivered to the parent LiveView via
      # `send(self(), {:flash, _})` from the submission handler, which is
      # processed after `render_submit/1` returns. Drain the mailbox via a
      # synchronous `:sys.get_state/1` before asserting on the render.
      _drain = :sys.get_state(view2.pid)

      # Second one should fail because the slot is now taken
      assert render(view2) =~ "This time slot is no longer available"
      refute has_element?(view2, "[data-testid='confirmation-heading']")
    end
  end
end
