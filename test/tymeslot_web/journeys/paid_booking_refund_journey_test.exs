defmodule TymeslotWeb.Journeys.PaidBookingRefundJourneyTest do
  @moduledoc """
  A paid booking refunded while Stripe is slow, end to end: a booker pays
  for a slot through the booking page, Stripe reports the payment through
  a signed Connect `checkout.session.completed`, the host refunds half of
  it from the payments page while Stripe does not answer, and Tymeslot
  finishes the refund once Stripe does, emailing the attendee.

  Only Stripe is stubbed, at the HTTP level; the webhook's signature is
  verified against the raw request body for real.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :payments

  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.StripeWebhookFixtures
  alias Tymeslot.Workers.SendBookingPaymentRefunded
  alias TymeslotWeb.BookingDriver

  @secret "whsec_refund_journey"
  @account_id "acct_REFUND_JOURNEY"
  @session_id "cs_refund_journey"
  @checkout_url "https://checkout.stripe.com/c/pay/cs_refund_journey"

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

    # Swoosh's test adapter posts {:email, ...} to whichever process calls
    # Mailer.deliver/1; pointing it here collects the delivered email.
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    %{user: user, profile: profile} = seed_booking_account("1", "refund-journey", "Etc/UTC")

    user =
      user
      |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    insert(:connect_account,
      user: user,
      stripe_account_id: @account_id,
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )

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
  test "a paid booking refunded while Stripe is slow is finished by Tymeslot", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    # Step 1: the booker pays for a slot, sent to Stripe Checkout.
    StripeStub.expect(
      :create_checkout_session,
      StripeStubResponses.checkout_session(@session_id, @checkout_url)
    )

    {:ok, view, _html} = live(build_conn(), "/#{profile.username}?timezone=Etc/UTC")
    BookingDriver.book(view, meeting_type: "paid-consult", until: :attendee)

    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => "Pay Pat", "email" => "pat@example.com", "message" => ""}
    })
    |> render_submit()

    assert_redirect(view, @checkout_url, 5_000)
    payment = Repo.get_by!(BookingPaymentSchema, stripe_checkout_session_id: @session_id)

    # Step 2: Stripe reports the payment on the host's account; the handler
    # reads the charge id off the payment intent.
    StripeStub.expect(
      :retrieve_payment_intent,
      StripeStubResponses.payment_intent("pi_refund_journey", "ch_refund_journey")
    )

    payload =
      StripeWebhookFixtures.connect_event(
        "checkout.session.completed",
        StripeFixtures.object("checkout_session_paid", %{
          "id" => @session_id,
          "client_reference_id" => payment.meeting_id,
          "payment_intent" => "pi_refund_journey",
          "payment_status" => "paid",
          "amount_total" => payment.amount_cents,
          "currency" => payment.currency
        }),
        @account_id
      )

    assert build_conn() |> post_connect(payload) |> response(200) == ""

    assert %{status: :paid, stripe_charge_id: "ch_refund_journey"} = Repo.reload!(payment)

    # Step 3: the host refunds half, and Stripe does not answer.
    StripeStub.expect(:create_refund, 3, {:transport_error, :timeout})

    host_conn = conn |> setup_session() |> log_in_user(user)
    {:ok, dashboard, _html} = live(host_conn, "/dashboard/integrations?tab=payments")

    dashboard
    |> element("[data-testid=payments-table] button[phx-value-id='#{payment.id}']")
    |> render_click()

    dashboard
    |> form("#refund-form", %{"refund_type" => "partial", "amount" => "25.00"})
    |> render_submit()

    render_async(dashboard, 5_000)

    assert render(dashboard) =~
             "Refund submitted. Stripe has not confirmed it yet; Tymeslot keeps trying and emails the attendee once it goes through."

    assert Repo.reload!(payment).refunded_amount_cents == 0

    # Step 4: Stripe answers the next attempt, which finds no refund made
    # by the lost ones and makes it.
    StripeStub.expect(:list_refunds, StripeFixtures.list([]))
    StripeStub.expect(:create_refund, StripeStubResponses.refund("re_refund_journey"))

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :payments, with_scheduled: true)

    {:ok, _dashboard, html} = live(host_conn, "/dashboard/integrations?tab=payments")
    assert html =~ "Partially refunded"
    assert %{refunded_amount_cents: 2500, status: :partially_refunded} = Repo.reload!(payment)

    # The attendee is emailed once the refund went through.
    assert [%{args: args}] = all_enqueued(worker: SendBookingPaymentRefunded)
    assert :ok = perform_job(SendBookingPaymentRefunded, args)
    assert_received {:email, %{to: [{_name, "pat@example.com"}], subject: subject}}
    assert subject =~ "Partial Refund Issued"

    assert Enum.map(StripeStub.requests(), & &1.operation) == [
             :create_checkout_session,
             :retrieve_payment_intent,
             :create_refund,
             :create_refund,
             :create_refund,
             :list_refunds,
             :create_refund
           ]
  end

  defp post_connect(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", StripeWebhookFixtures.signature(payload, @secret))
    |> post("/webhooks/stripe/connect", payload)
  end
end
