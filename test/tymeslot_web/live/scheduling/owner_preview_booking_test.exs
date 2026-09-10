defmodule TymeslotWeb.Live.Scheduling.OwnerPreviewBookingTest do
  @moduledoc """
  What an owner previewing their own booking page must and must not do.

  Both properties here were broken together in issue #96, and each was
  invisible from the other end. The dashboard's "Embed & Share → Live Preview"
  built its iframe URL by hand with `?preview=true` and no token, so every
  preview booking hit the fail-closed branch and told the organiser their
  "Preview session expired" the moment they pressed Book Meeting. Meanwhile
  the gates ran before the preview-versus-real decision, so the attempts that
  were about to be refused still spent the public per-IP allowance — an
  organiser testing their page locked real visitors out of booking it.

  Fixing that surfaced the opposite fault in the sibling preview modes: Popup
  and Floating delegate to `embed.js`, whose parameter allowlist dropped the
  token, so their previews booked for real. Both directions are covered here,
  because a simulated booking and a persisted one end on the same screen and
  only the database tells them apart.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.PreviewToken

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "previewowner",
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    insert(:calendar_integration, user: user, provider: "google", is_active: true)
    event_type = insert(:meeting_type, user: user, duration_minutes: 30, is_active: true)

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    %{user: user, profile: profile, event_type: event_type}
  end

  describe "a preview carrying a valid owner token" do
    test "simulates the booking rather than refusing it", %{
      conn: conn,
      user: user,
      profile: profile,
      event_type: event_type
    } do
      view = navigate_to_preview(conn, profile, event_type, PreviewToken.sign(user.id))

      html = submit_booking(view, "owner-preview@example.com")

      refute html =~ "Preview session expired"
      assert Repo.aggregate(MeetingSchema, :count, :id) == 0
    end

    test "simulates an embedded preview too, whatever mode opened it", %{
      conn: conn,
      user: user,
      profile: profile,
      event_type: event_type
    } do
      # The Popup and Floating preview modes do not build their own URL: they
      # hand the token to embed.js, which builds an *embedded* one — `embed=1`
      # and `parent-origin` alongside the two preview params. Before the token
      # could reach it, embed.js dropped it at its allowlist and both modes
      # persisted a real meeting and mailed the address the organiser typed,
      # while ending on the same "Meeting Confirmed!" screen a simulation does.
      view =
        navigate_to_booking_form(conn, profile, event_type, [
          {"preview", "true"},
          {"preview_token", PreviewToken.sign(user.id)},
          {"embed", "1"},
          {"parent-origin", "http://localhost:4000"}
        ])

      html = submit_booking(view, "popup-preview@example.com")

      refute html =~ "Preview session expired"
      assert Repo.aggregate(MeetingSchema, :count, :id) == 0
    end

    test "does not spend the public per-IP booking allowance", %{
      conn: conn,
      user: user,
      profile: profile,
      event_type: event_type
    } do
      # One short of the limit, so the next *chargeable* submission is refused
      # and the next exempt one is not. That makes the assertion below turn on
      # the preview alone rather than on the size of the budget.
      client_ip = spend_booking_budget_to_one_remaining(conn, profile, event_type)

      preview = navigate_to_preview(conn, profile, event_type, PreviewToken.sign(user.id))
      submit_booking(preview, "owner-preview@example.com")

      # The visitor's turn. Their submission is the 10th chargeable one and
      # must still go through; if the preview was charged, it was the 10th and
      # this is the 11th.
      visitor = navigate_to_booking_form(conn, profile, event_type)
      html = submit_booking(visitor, "real-visitor@example.com")

      refute html =~ "Too many booking attempts"
      assert client_ip_for(visitor) == client_ip
      wait_until(fn -> Repo.aggregate(MeetingSchema, :count, :id) == 1 end)
    end
  end

  describe "a preview claim with no valid token" do
    test "is refused, and is still charged to the rate limit", %{
      conn: conn,
      profile: profile,
      event_type: event_type
    } do
      # `?preview=true` is forgeable by anyone, so exempting it would hand out
      # a one-parameter bypass of the booking limit. It buys no booking, but it
      # does cost an outbound reCAPTCHA verification, so it stays chargeable.
      view = navigate_to_preview(conn, profile, event_type, nil)

      assert submit_booking(view, "forged-preview@example.com") =~ "Preview session expired"
      assert Repo.aggregate(MeetingSchema, :count, :id) == 0

      # Saturating from here takes 9 more, not 10, because this attempt counted.
      client_ip = client_ip_for(view)
      Enum.each(1..9, fn _i -> RateLimiter.check_booking_submission_limit(client_ip) end)

      visitor = navigate_to_booking_form(conn, profile, event_type)
      assert submit_booking(visitor, "blocked@example.com") =~ "Too many booking attempts"
    end
  end

  defp navigate_to_preview(conn, profile, event_type, nil) do
    navigate_to_booking_form(conn, profile, event_type, [{"preview", "true"}])
  end

  defp navigate_to_preview(conn, profile, event_type, token) do
    navigate_to_booking_form(
      conn,
      profile,
      event_type,
      [{"preview", "true"}, {"preview_token", token}]
    )
  end

  # Burns 9 of the 10 per-IP submissions on the bucket the LiveView will use,
  # and returns that bucket's key so the caller can assert it stayed the same.
  defp spend_booking_budget_to_one_remaining(conn, profile, event_type) do
    client_ip =
      conn
      |> navigate_to_booking_form(profile, event_type)
      |> client_ip_for()

    Enum.each(1..9, fn _i -> RateLimiter.check_booking_submission_limit(client_ip) end)

    client_ip
  end

  defp submit_booking(view, email) do
    params = %{
      "name" => "Preview Booker",
      "email" => email,
      "message" => "",
      "website" => ""
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    _drain = :sys.get_state(view.pid)
    render(view)
  end

  defp client_ip_for(view) do
    state = :sys.get_state(view.pid)
    state.socket.assigns[:client_ip] || "unknown"
  end
end
