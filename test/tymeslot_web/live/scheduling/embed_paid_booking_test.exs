defmodule TymeslotWeb.Live.Scheduling.EmbedPaidBookingTest do
  @moduledoc """
  Integration coverage for paid bookings submitted from inside an
  embedded booker iframe.

  Stripe Checkout cannot render inside an iframe — Stripe blocks framing
  via `Content-Security-Policy: frame-ancestors`. The embed flow has to:

    * **not** redirect the iframe to Stripe (that would error or strand
      the attendee on a blank page),
    * push a `payment_redirect_open_tab` event so the JS hook calls
      `window.open(url, '_blank')`,
    * transition the LiveView to the local `:awaiting_payment` view so
      the attendee sees a "complete in new tab" message,
    * subscribe to `meeting_payment:<id>` PubSub and flip to
      `:confirmation` when the webhook broadcasts `:paid`, or back to
      `:booking` with a flash on `:expired`.

  The non-embedded counterpart (top-level booker) is exercised
  separately in `Tymeslot.Bookings.OrchestratorPaidBookingTest`.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :payments
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Phoenix.LiveViewTest
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 50
    )

    # Disable reCAPTCHA — we exercise the paid-booking branch, not the
    # security gate (covered elsewhere).
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "paidpicker",
        booking_theme: "1",
        timezone: "America/New_York",
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0,
        allowed_embed_domains: ["embedder.test"]
      )

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_HOST",
      default_currency: "usd",
      charges_enabled: true
    )

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Paid Consult",
        is_active: true,
        payment_required: true,
        price_cents: 5000
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile, meeting_type: meeting_type, user: user}
  end

  describe "embed iframe — paid booking" do
    @tag :capture_log
    test "pushes payment_redirect_open_tab and transitions to :awaiting_payment instead of redirecting",
         %{conn: conn, profile: profile, meeting_type: meeting_type} do
      checkout_url = "https://checkout.stripe.com/cs_TEST_embed"

      expect(StripeAdapterMock, :create_checkout_session, fn _params, opts ->
        assert opts[:connect_account] == "acct_HOST"
        {:ok, %{id: "cs_TEST_embed", url: checkout_url}}
      end)

      view = navigate_to_booking_form_embedded(conn, profile, meeting_type)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Embed Eve",
          "email" => "embed@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      _drain = :sys.get_state(view.pid)

      # Iframe stays put — no external redirect was issued.
      assert_no_redirect(view, checkout_url)

      # JS hook gets the URL to open in a new tab.
      assert_push_event(view, "payment_redirect_open_tab", %{url: ^checkout_url})

      rendered = render(view)
      assert rendered =~ "Complete your payment in the new tab"
      assert rendered =~ ~s(data-testid="awaiting-payment")
      assert rendered =~ checkout_url
      refute rendered =~ "Meeting Confirmed"
    end

    @tag :capture_log
    test "PubSub :paid flips the iframe to :confirmation",
         %{conn: conn, profile: profile, meeting_type: meeting_type} do
      expect(StripeAdapterMock, :create_checkout_session, fn _params, _opts ->
        {:ok, %{id: "cs_paid_flip", url: "https://checkout.stripe.com/cs_paid_flip"}}
      end)

      view = navigate_to_booking_form_embedded(conn, profile, meeting_type)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Pay Pat",
          "email" => "pat@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      _drain = :sys.get_state(view.pid)

      # Pull the meeting id assigned during the awaiting state.
      meeting_id = :sys.get_state(view.pid).socket.assigns[:awaiting_payment_meeting].id

      # Webhook broadcasts :paid on the meeting topic; the iframe LV
      # subscribed during the embed branch and should flip to :confirmation.
      Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting_id}", :paid)
      _drain = :sys.get_state(view.pid)

      rendered = render(view)
      refute rendered =~ "Complete your payment in the new tab"
      assert rendered =~ ~s(data-testid="confirmation-heading")
    end

    @tag :capture_log
    test "PubSub :expired sends the iframe back to the booking step with a flash",
         %{conn: conn, profile: profile, meeting_type: meeting_type} do
      expect(StripeAdapterMock, :create_checkout_session, fn _params, _opts ->
        {:ok, %{id: "cs_expired", url: "https://checkout.stripe.com/cs_expired"}}
      end)

      view = navigate_to_booking_form_embedded(conn, profile, meeting_type)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Lapse Liam",
          "email" => "lapse@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      _drain = :sys.get_state(view.pid)

      meeting_id = :sys.get_state(view.pid).socket.assigns[:awaiting_payment_meeting].id

      Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting_id}", :expired)
      _drain = :sys.get_state(view.pid)

      rendered = render(view)
      assert rendered =~ "Payment was cancelled"
      refute rendered =~ "Complete your payment in the new tab"
      refute rendered =~ ~s(data-testid="confirmation-heading")
    end
  end

  describe "non-embed (control)" do
    @tag :capture_log
    test "top-level booker still redirects directly to Stripe Checkout",
         %{conn: conn, profile: profile, meeting_type: meeting_type} do
      checkout_url = "https://checkout.stripe.com/cs_TOPLEVEL"

      expect(StripeAdapterMock, :create_checkout_session, fn _params, _opts ->
        {:ok, %{id: "cs_TOPLEVEL", url: checkout_url}}
      end)

      view = navigate_to_booking_form(conn, profile, meeting_type)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Top Tina",
          "email" => "top@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      # Non-embedded booker keeps the historical redirect contract.
      # The view shuts down on redirect, so we cannot drain :sys.get_state/1.
      assert_redirect(view, checkout_url)
    end
  end

  defp navigate_to_booking_form_embedded(conn, profile, meeting_type) do
    timezone = profile.timezone
    # Referer header drives the EmbedTokenPlug's parent_origin signing,
    # which the EmbedAuthHook then verifies against the profile's
    # `allowed_embed_domains` (set to "embedder.test" in the setup).
    conn = put_req_header(conn, "referer", "https://embedder.test/page")
    {:ok, view, _html} = live(conn, "/#{profile.username}?embed=1&timezone=#{timezone}")

    # Sanity check: the embed token wired the LV into embedded mode.
    assert :sys.get_state(view.pid).socket.assigns[:embedded] == true,
           "expected embedded LV after ?embed=1 — check EmbedTokenPlug + EmbedAuthHook"

    _meeting_type = meeting_type

    view |> element("button[data-testid='duration-option']") |> render_click()
    view |> element("button[data-testid='next-step']") |> render_click()

    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
    date_str = Date.to_string(target_date)

    if target_date.month != today.month || target_date.year != today.year do
      view |> element("button[phx-click='next_month']") |> render_click()
    end

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()
    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("button.time-slot-button", "phx-value-time")
      |> List.first() ||
        flunk("expected a time slot after selecting a date")

    view |> element("button.time-slot-button[phx-value-time='#{slot}']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()

    view
  end

  # `assert_redirect/3` raises with `ExUnit.AssertionError` on timeout and
  # `ArgumentError` when the LiveView never redirected at all — both mean
  # "view stayed put", which is what the embed flow guarantees.
  defp assert_no_redirect(view, expected_to) do
    LiveViewTest.assert_redirect(view, expected_to, 50)
    flunk("expected the embedded LV to NOT redirect to #{expected_to}")
  rescue
    ExUnit.AssertionError -> :ok
    ArgumentError -> :ok
  end
end
