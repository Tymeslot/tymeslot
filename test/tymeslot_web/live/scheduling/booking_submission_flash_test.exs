defmodule TymeslotWeb.Live.Scheduling.BookingSubmissionFlashTest do
  @moduledoc """
  Regression test for Task 95 — flash messages emitted by the booking
  submission pipeline must reach the parent scheduling LiveView.

  The booking form is rendered inside a `Phoenix.LiveComponent` and
  `BookingSubmissionHandlerComponent` decorates its socket with flashes on
  every failure branch. Those flashes used to be silently dropped because
  `put_flash/3` on a component socket never reaches the root LiveView.
  We now forward them through `TymeslotWeb.Live.Shared.Flash.put_flash/3`,
  which the scheduling LiveView picks up in `handle_info({:flash, _}, _)`.
  This test drives one of those failure branches and asserts the flash
  renders in the parent view.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    # Disable reCAPTCHA — we are exercising the validation-error branch,
    # which runs after the honeypot gate but before reCAPTCHA. Disabling
    # keeps the test hermetic regardless of env configuration.
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "testuser",
        timezone: "America/New_York",
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    insert(:calendar_integration, user: user, provider: "google", is_active: true)

    event_type = insert(:meeting_type, user: user, duration_minutes: 30, is_active: true)

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    %{profile: profile, event_type: event_type}
  end

  test "forwards rate-limit error flash from booking component to parent LiveView", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    view = navigate_to_booking_form(conn, profile, event_type)

    # The scheduling LiveView captures the client IP during mount from
    # the test conn's peer data. Saturate the booking-submission
    # rate-limit bucket for that key so the next submit hits
    # `BookingSubmissionHandlerComponent.check_rate_limit/1`'s `{:deny, _}`
    # branch — the branch that used to silently drop its "Too many
    # booking attempts." flash.
    client_ip = client_ip_for(view)
    saturate_booking_rate_limit(client_ip)

    params = %{
      "name" => "Rate Limited",
      "email" => "rate@example.com",
      "message" => "",
      "website" => ""
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    # The flash is delivered to the parent via `send(self(), {:flash, _})`
    # from the submission handler. That message is processed asynchronously
    # relative to the `phx-submit` reply, so drain the LiveView's mailbox
    # via a synchronous `:sys.get_state/1` before asserting on the render.
    _drain = :sys.get_state(view.pid)

    assert render(view) =~ "Too many booking attempts"
  end

  defp saturate_booking_rate_limit(client_ip) do
    # `check_booking_submission_limit/1` allows 10 requests per 20 minutes.
    # Burn through the budget so the next call from the LiveView returns
    # `{:deny, _}`.
    Enum.each(1..10, fn _i ->
      RateLimiter.check_booking_submission_limit(client_ip)
    end)
  end

  # Reads the `client_ip` assigned on the root scheduling LiveView. The
  # LiveView captures it during mount from the test conn's peer data, so
  # mirroring that value is the only way to saturate the correct bucket.
  defp client_ip_for(view) do
    state = :sys.get_state(view.pid)
    state.socket.assigns[:client_ip] || "unknown"
  end
end
