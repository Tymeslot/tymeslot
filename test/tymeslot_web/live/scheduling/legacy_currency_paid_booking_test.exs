defmodule TymeslotWeb.Live.Scheduling.LegacyCurrencyPaidBookingTest do
  @moduledoc """
  A booker paying a host whose Stripe account was opened, before the currency
  allowlist was enforced, in a currency outside it.

  A currency counted in hundredths, as every stored price is (Romanian lei
  here), is still charged the stored price, in the account's currency. One
  counted in whole units (yen) would be charged a hundred times over, so the
  booking is refused with the "payments unavailable" message and no meeting
  is made.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :payments
  @moduletag :live

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

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
        username: "legacypayee",
        booking_theme: "1",
        timezone: "Europe/Bucharest"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Paid Consult",
        is_active: true,
        payment_required: true,
        price_cents: 15_000
      )

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  # Inserted directly: the changeset would refuse either currency now.
  defp legacy_account(user, currency) do
    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_LEGACY",
      default_currency: currency,
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )
  end

  defp submit(view) do
    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => "Rada Booker", "email" => "rada@example.com", "message" => ""}
    })
    |> render_submit()
  end

  @tag :capture_log
  test "a two-decimal legacy currency is charged the stored price in that currency",
       %{conn: conn, user: user, profile: profile, meeting_type: meeting_type} do
    legacy_account(user, "ron")
    checkout_url = "https://checkout.stripe.com/cs_legacy_ron"
    test_pid = self()

    expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
      send(test_pid, {:checkout, params, opts})
      {:ok, %{id: "cs_legacy_ron", url: checkout_url}}
    end)

    view = navigate_to_booking_form(conn, profile, meeting_type)
    submit(view)

    # The submission finishes in a handler component, so allow it a moment.
    assert_redirect(view, checkout_url, 2_000)

    assert_received {:checkout, %{line_items: [%{price_data: price_data}]}, opts}
    assert %{currency: "ron", unit_amount: 15_000} = price_data
    assert opts[:connect_account] == "acct_LEGACY"

    meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
    assert meeting.status == "awaiting_payment"
    assert BookingPaymentQueries.by_meeting_id(meeting.id).currency == "ron"
  end

  @tag :capture_log
  test "a zero-decimal legacy currency is refused before any meeting is made",
       %{conn: conn, user: user, profile: profile, meeting_type: meeting_type} do
    legacy_account(user, "jpy")

    expect(StripeAdapterMock, :create_checkout_session, 0, fn _params, _opts ->
      flunk("no checkout session may be created")
    end)

    view = navigate_to_booking_form(conn, profile, meeting_type)

    submit(view)

    # The submission finishes in a handler component; wait for it.
    _drain = :sys.get_state(view.pid)
    assert render(view) =~ "Payments are not available for this booking."
    refute Repo.get_by(MeetingSchema, organizer_user_id: user.id)
  end
end
