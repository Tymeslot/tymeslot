defmodule Tymeslot.MeetingPayments.ConnectHttpTest do
  @moduledoc """
  The paid-booking calls to Stripe, made on the host's connected account,
  observed at the HTTP level: each case runs the real Core function and reads
  the request `Tymeslot.StripeStub` recorded.
  """
  # The feature gate and the meeting-payments flag are global config.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments
  @moduletag :integration

  import Ecto.Query
  import Tymeslot.StripeConnectTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ChargeBackfill
  alias Tymeslot.MeetingPayments.CheckoutSessions
  alias Tymeslot.MeetingPayments.ConnectAccountRetirement
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Profiles
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  describe "checkout" do
    setup :enable_meeting_payments

    test "a booking checkout is created on the host's account under the booking's key" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      {:ok, _profile} = Profiles.update_booking_theme(profile, "1")

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_HOST",
        default_currency: "eur",
        charges_enabled: true
      )

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Consult",
          payment_required: true,
          price_cents: 5000
        )

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_ref: meeting_type,
          status: :awaiting_payment
        )

      # Stripe sends `payment_intent: null` for an open session; one it does
      # send is kept.
      session =
        StripeFixtures.object("checkout_session_payment", %{"payment_intent" => "pi_AT_CREATE"})

      StripeStub.expect(:create_checkout_session, session)

      assert {:ok, %{checkout_url: url, booking_payment: payment}} =
               CheckoutSessions.create_session_for_booking(meeting)

      assert url == session["url"]
      assert payment.stripe_checkout_session_id == session["id"]
      assert payment.stripe_payment_intent_id == "pi_AT_CREATE"

      assert [%{method: :post, path: "/v1/checkout/sessions", headers: headers, form: form}] =
               StripeStub.requests(:create_checkout_session)

      assert headers["stripe-account"] == "acct_HOST"
      assert headers["idempotency-key"] == "tymeslot:checkout:#{meeting.id}"

      assert [%{"price_data" => %{"product_data" => %{"name" => name}}}] = form["line_items"]
      assert is_binary(name) and name != ""
      assert form["invoice_creation"]["enabled"] == "true"
    end

    test "expiring a session on disconnect goes to the host's account" do
      user = insert(:user)
      insert(:connect_account, user: user, stripe_account_id: "acct_DISCONNECT")
      meeting = insert(:meeting, status: :awaiting_payment, organizer_user_id: user.id)

      insert(:booking_payment,
        host_user_id: user.id,
        meeting: meeting,
        stripe_account_id: "acct_DISCONNECT",
        stripe_checkout_session_id: "cs_OPEN",
        status: :pending
      )

      StripeStub.expect(
        :expire_checkout_session,
        StripeFixtures.object("checkout_session_expired", %{"id" => "cs_OPEN"})
      )

      assert {:ok, %{cancelled_count: 1}} = ConnectAccountRetirement.disconnect(user)

      assert [%{method: :post, path: "/v1/checkout/sessions/cs_OPEN/expire", headers: headers}] =
               StripeStub.requests(:expire_checkout_session)

      assert headers["stripe-account"] == "acct_DISCONNECT"
    end
  end

  describe "connected account" do
    setup :enable_meeting_payments

    test "the connected account is read with the Stripe-Account header" do
      user = insert(:user)
      state = started_state(user)

      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(200, Jason.encode!(%{"stripe_user_id" => "acct_OAUTH"}))
      end)

      StripeStub.expect(
        :retrieve_account,
        StripeFixtures.object("account", %{
          "id" => "acct_OAUTH",
          "country" => "FR",
          "default_currency" => "eur"
        })
      )

      assert {:ok, account} = ConnectAccounts.complete_oauth_callback(user, "ac_CODE", state)

      assert account.stripe_account_id == "acct_OAUTH"
      assert account.default_currency == "eur"

      assert [%{method: :get, path: "/v1/account", headers: headers}] =
               StripeStub.requests(:retrieve_account)

      assert headers["stripe-account"] == "acct_OAUTH"
    end
  end

  describe "charges" do
    test "the charge id is backfilled from the expanded latest charge" do
      payment =
        insert(:booking_payment,
          stripe_account_id: "acct_BACKFILL",
          stripe_payment_intent_id: "pi_test1",
          status: :paid
        )

      StripeStub.expect(
        :retrieve_payment_intent,
        StripeFixtures.object("payment_intent_with_latest_charge", %{
          "latest_charge" => StripeFixtures.object("charge", %{"id" => "ch_REAL"})
        })
      )

      assert {:ok, %{stripe_charge_id: "ch_REAL"}} = ChargeBackfill.backfill(payment, "pi_test1")
      assert BookingPaymentQueries.get(payment.id).stripe_charge_id == "ch_REAL"

      assert [
               %{
                 method: :get,
                 path: "/v1/payment_intents/pi_test1",
                 query: query,
                 headers: headers
               }
             ] =
               StripeStub.requests(:retrieve_payment_intent)

      assert query["expand"] == ["latest_charge"]
      assert headers["stripe-account"] == "acct_BACKFILL"
    end

    test "the receipt URL is read from the charge" do
      charge = StripeFixtures.object("charge", %{"id" => "ch_1"})
      StripeStub.expect(:retrieve_charge, charge)

      assert BookingPayments.retrieve_charge_receipt_url("ch_1", "acct_1") ==
               {:ok, charge["receipt_url"]}

      assert [%{method: :get, path: "/v1/charges/ch_1", headers: headers}] =
               StripeStub.requests(:retrieve_charge)

      assert headers["stripe-account"] == "acct_1"
    end
  end

  describe "refunds" do
    test "a refund is created on the host's account under its attempt's key" do
      payment =
        insert(:paid_booking_payment,
          meeting: insert(:meeting),
          stripe_account_id: "acct_REFUND",
          stripe_charge_id: "ch_test1"
        )

      # The charge's total also holds a 500 refund made outside Tymeslot,
      # which its own report records: this refund raises the total by its
      # 1000 only.
      StripeStub.expect(
        :create_refund,
        StripeFixtures.object("refund_with_charge", %{
          "amount" => 1000,
          "charge" => StripeFixtures.object("charge", %{"amount_refunded" => 1500})
        })
      )

      assert {:ok, refund} = MeetingPayments.refund_now(payment, 1000, :host)

      assert %{refunded_amount_cents: 1000, status: :partially_refunded} =
               BookingPaymentQueries.get(payment.id)

      assert [%{method: :post, path: "/v1/refunds", form: form, headers: headers}] =
               StripeStub.requests(:create_refund)

      assert form["charge"] == "ch_test1"
      assert form["amount"] == "1000"
      assert form["expand"] == ["charge"]
      assert form["metadata"]["meeting_id"] == payment.meeting_id
      assert headers["stripe-account"] == "acct_REFUND"
      assert headers["idempotency-key"] == "tymeslot:refund:#{refund.id}:1"
    end

    test "a rate-limited refund is sent once and stays pending" do
      payment = insert(:paid_booking_payment, meeting: insert(:meeting))

      StripeStub.expect(:create_refund, {:error_fixture, "rate_limit"})

      assert {:pending, %{status: :pending}} = MeetingPayments.refund_now(payment, 600, :host)

      assert length(StripeStub.requests(:create_refund)) == 1
      assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 0
    end
  end

  describe "reconciliation" do
    test "reconciliation reads the session on the host's account" do
      meeting = insert(:meeting, status: :awaiting_payment)

      payment =
        insert(:booking_payment,
          meeting: meeting,
          status: :pending,
          stripe_account_id: "acct_RECONCILE",
          stripe_checkout_session_id: "cs_STALE"
        )

      stale = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)

      {1, _rows} =
        Repo.update_all(
          from(b in BookingPaymentSchema, where: b.id == ^payment.id),
          set: [inserted_at: stale]
        )

      StripeStub.expect(
        :retrieve_checkout_session,
        StripeFixtures.object("checkout_session_payment", %{
          "id" => "cs_STALE",
          "payment_status" => "paid",
          "status" => "complete",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_RECONCILED",
          "amount_total" => payment.amount_cents,
          "currency" => payment.currency
        })
      )

      StripeStub.stub(
        :retrieve_payment_intent,
        StripeFixtures.object("payment_intent_with_latest_charge", %{
          "id" => "pi_RECONCILED",
          "latest_charge" => StripeFixtures.object("charge", %{"id" => "ch_RECONCILED"})
        })
      )

      assert {:ok, %{reconciled: 1}} = perform_job(ReconcileAwaitingPayments, %{})

      assert %{status: :paid, stripe_payment_intent_id: "pi_RECONCILED"} =
               BookingPaymentQueries.get(payment.id)

      assert {:ok, %{status: :confirmed}} = MeetingQueries.get_meeting(meeting.id)

      assert [%{method: :get, path: "/v1/checkout/sessions/cs_STALE", headers: headers}] =
               StripeStub.requests(:retrieve_checkout_session)

      assert headers["stripe-account"] == "acct_RECONCILE"
    end
  end
end
