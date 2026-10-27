defmodule TymeslotWeb.Live.Scheduling.StripeConnectOnboardingJourneyTest do
  @moduledoc """
  A host connecting Stripe, end to end: the host starts Connect onboarding
  from the dashboard, Stripe reports the account can take charges through a
  signed `account.updated` delivered to the Connect webhook endpoint, and the
  host's paid meeting type, hidden from the booking page until then, can be
  booked through to Stripe Checkout.

  The controller test stops at the redirect to Stripe and the handler test
  calls the handler directly; this walks the HTTP endpoints and the public
  page together. Only the Stripe adapter is mocked; the webhook's signature is
  verified against the raw request body for real.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :payments

  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.BookingDriver

  @secret "whsec_connect_journey"
  @account_id "acct_JOURNEY"
  @checkout_url "https://checkout.stripe.com/c/pay/cs_journey"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      stripe_connect_webhook_secret: @secret
    )

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, recaptcha) end)

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    %{user: user, profile: profile} = seed_booking_account("1", "connect-journey", "Etc/UTC")

    user =
      user
      |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    # A price kept from before: a paid type stays priced while its host cannot
    # take payments, and is simply not offered until they can.
    insert(:meeting_type,
      user: user,
      name: "Paid Consult",
      duration_minutes: 30,
      is_active: true,
      payment_required: true,
      price_cents: 5000
    )

    %{user: user, profile: profile}
  end

  @tag :capture_log
  test "a host who finishes Connect onboarding can sell their paid meeting type", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    # Step 1: the host starts onboarding and is sent to Stripe.
    expect(StripeAdapterMock, :create_account, fn _params, _opts ->
      {:ok, %{id: @account_id, default_currency: "eur"}}
    end)

    expect(StripeAdapterMock, :create_account_link, fn params ->
      assert params.account == @account_id
      {:ok, %{url: "https://connect.stripe.com/setup/journey"}}
    end)

    host_conn =
      conn |> setup_session() |> log_in_user(user) |> post("/dashboard/payments/connect")

    assert redirected_to(host_conn, 302) == "https://connect.stripe.com/setup/journey"

    account = Repo.get_by!(ConnectAccountSchema, user_id: user.id)
    assert account.stripe_account_id == @account_id
    refute account.charges_enabled

    # Until Stripe says otherwise, the paid type is not offered.
    refute "paid-consult" in offered_types(profile)

    # Step 2: Stripe reports the account can take charges.
    now = System.os_time(:second)

    payload =
      Jason.encode!(%{
        "id" => "evt_journey_#{System.unique_integer([:positive])}",
        "type" => "account.updated",
        "created" => now,
        "data" => %{
          "object" => %{
            "id" => @account_id,
            "object" => "account",
            "charges_enabled" => true,
            "payouts_enabled" => true,
            "details_submitted" => true,
            "requirements" => %{"disabled_reason" => nil}
          }
        }
      })

    webhook_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "stripe-signature",
        PaymentTestHelpers.generate_stripe_signature(payload, @secret)
      )
      |> post("/webhooks/stripe/connect", payload)

    assert response(webhook_conn, 200) == ""

    # Any work the event queued runs before the booker arrives.
    assert %{failure: 0} = Oban.drain_queue(queue: :payments, with_recursion: true)

    account = Repo.reload!(account)
    assert account.charges_enabled
    assert account.payouts_enabled

    # Step 3: a booker picks the paid type and is sent to Stripe Checkout,
    # charged on the host's connected account.
    assert "paid-consult" in offered_types(profile)

    test_pid = self()

    expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
      send(test_pid, {:checkout, params, opts})
      {:ok, %{id: "cs_journey", url: @checkout_url}}
    end)

    {:ok, view, _html} = live(build_conn(), "/#{profile.username}?timezone=Etc/UTC")
    BookingDriver.book(view, meeting_type: "paid-consult", until: :attendee)

    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => "Pay Pat", "email" => "pat@example.com", "message" => ""}
    })
    |> render_submit()

    assert_redirect(view, @checkout_url, 5_000)
    assert_received {:checkout, _params, opts}
    assert opts[:connect_account] == @account_id
  end

  defp offered_types(profile) do
    {:ok, view, _html} = live(build_conn(), "/#{profile.username}?timezone=Etc/UTC")
    BookingDriver.meeting_types(view)
  end
end
