defmodule Tymeslot.MeetingPayments.CheckoutSessionsTest do
  # async: false — this suite mutates the global :feature_access_checker and
  # :meeting_payments_enabled application env, which must not race other tests.
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :payments

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.CheckoutSessions
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Profiles

  setup :verify_on_exit!

  setup do
    # Checkout enforces server-side :meeting_payments access. Pin Core's default
    # checker (a downstream overlay's test env otherwise merges in a
    # subscription checker, which returns :pro_required for a bare user) and
    # enable the Core opt-in flag so the host is permitted to take payments in
    # these tests.
    previous_checker = Application.get_env(:tymeslot, :feature_access_checker)

    Application.put_env(
      :tymeslot,
      :feature_access_checker,
      Tymeslot.Features.DefaultAccessChecker
    )

    previous_payments = Application.get_env(:tymeslot, :meeting_payments_enabled)
    Application.put_env(:tymeslot, :meeting_payments_enabled, true)

    on_exit(fn ->
      Application.put_env(:tymeslot, :meeting_payments_enabled, previous_payments)
      Application.put_env(:tymeslot, :feature_access_checker, previous_checker)
    end)

    user = insert(:user)
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{booking_theme: "1"})

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

    %{user: user, meeting_type: meeting_type}
  end

  describe "create_session_for_booking/1" do
    test "creates session with correct application_fee, currency, theme slug, and snapshot",
         %{user: user, meeting_type: mt} do
      Application.put_env(:tymeslot, :payment_application_fee_bp, 50)
      on_exit(fn -> Application.put_env(:tymeslot, :payment_application_fee_bp, 0) end)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_ref: mt,
          attendee_email: "alice@example.com",
          attendee_name: "Alice",
          attendee_locale: "en",
          status: "awaiting_payment"
        )

      expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
        assert opts[:connect_account] == "acct_HOST"
        assert opts[:idempotency_key] == "checkout:#{meeting.id}"
        assert hd(params.line_items).price_data.currency == "eur"
        assert hd(params.line_items).price_data.unit_amount == 5000
        assert params.payment_intent_data.application_fee_amount == 25
        assert params.success_url =~ "/themes/quill/payment-processing/#{meeting.id}"
        assert params.success_url =~ "session_id={CHECKOUT_SESSION_ID}"
        assert params.cancel_url =~ "/themes/quill/payment-cancelled/#{meeting.id}"
        assert params.client_reference_id == meeting.id
        # Checkout Sessions must NOT carry `automatic_payment_methods` (a
        # PaymentIntent-only param Stripe rejects); methods come from the
        # dashboard config when the param is omitted.
        refute Map.has_key?(params, :automatic_payment_methods)
        assert params.customer_email == "alice@example.com"
        assert params.locale == "en"

        {:ok,
         %{id: "cs_TEST", url: "https://checkout.stripe.com/cs_TEST", payment_intent: "pi_TEST"}}
      end)

      assert {:ok, %{checkout_url: url, booking_payment: bp}} =
               CheckoutSessions.create_session_for_booking(meeting)

      assert url =~ "checkout.stripe.com"
      assert bp.amount_cents == 5000
      assert bp.application_fee_cents == 25
      assert bp.currency == "eur"
      assert bp.attendee_email == "alice@example.com"
      assert bp.host_user_id == user.id
      assert bp.host_email == user.email
      assert bp.meeting_type_name == "Consult"
      assert bp.booking_theme_id == "1"
      assert bp.stripe_account_id == "acct_HOST"
      assert bp.stripe_checkout_session_id == "cs_TEST"
      # Captured at creation so charge-based webhooks have a join key before the
      # checkout.session.completed handler backfills the charge id.
      assert bp.stripe_payment_intent_id == "pi_TEST"
      assert bp.status == "pending"
    end

    test "returns :payments_unavailable when host has no charges-enabled account",
         %{user: user, meeting_type: mt} do
      # Manually disable charges via direct query
      account = ConnectAccountQueries.live_for_user(user.id)

      {:ok, _disabled} =
        ConnectAccountQueries.update(account, %{
          charges_enabled: false
        })

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_ref: mt,
          attendee_email: "alice@example.com",
          status: "awaiting_payment"
        )

      assert {:error, :payments_unavailable} =
               CheckoutSessions.create_session_for_booking(meeting)
    end

    test "omits application_fee_amount from payment_intent_data when fee is zero",
         %{user: user, meeting_type: mt} do
      Application.put_env(:tymeslot, :payment_application_fee_bp, 0)
      on_exit(fn -> Application.put_env(:tymeslot, :payment_application_fee_bp, 0) end)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_ref: mt,
          attendee_email: "bob@example.com",
          attendee_name: "Bob",
          attendee_locale: "en",
          status: "awaiting_payment"
        )

      expect(StripeAdapterMock, :create_checkout_session, fn params, _opts ->
        refute Map.has_key?(params.payment_intent_data, :application_fee_amount)
        assert params.payment_intent_data.metadata.meeting_id == meeting.id
        {:ok, %{id: "cs_ZERO_FEE", url: "https://checkout.stripe.com/cs_ZERO_FEE"}}
      end)

      assert {:ok, %{booking_payment: bp}} =
               CheckoutSessions.create_session_for_booking(meeting)

      assert bp.application_fee_cents == 0
    end

    test "leaves a pending booking_payment (no session id) when Stripe Checkout fails",
         %{user: user, meeting_type: mt} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_ref: mt,
          attendee_email: "alice@example.com",
          status: "awaiting_payment"
        )

      expect(StripeAdapterMock, :create_checkout_session, fn _params, _opts ->
        {:error, :stripe_unreachable}
      end)

      assert {:error, :stripe_unreachable} =
               CheckoutSessions.create_session_for_booking(meeting)

      # The Stripe call now runs OUTSIDE any DB transaction, so the row inserted
      # before it is NOT rolled back. It remains `pending` with no checkout
      # session id — exactly the shape the ReconcileAwaitingPayments sweeper
      # treats as stale and cleans up. The pre-Stripe insert is the deliberate
      # trade-off for not holding a pooled DB connection across the network call.
      bp = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert bp
      assert bp.status == "pending"
      assert is_nil(bp.stripe_checkout_session_id)
    end

    test "rejects checkout when the host lacks :meeting_payments access",
         %{user: user, meeting_type: mt} do
      # Forged/raced booking: the host's plan lapsed (feature disabled) even
      # though Stripe still reports charges_enabled. No Stripe call must be made.
      Application.put_env(:tymeslot, :meeting_payments_enabled, false)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_ref: mt,
          attendee_email: "alice@example.com",
          status: "awaiting_payment"
        )

      assert {:error, :payments_unavailable} =
               CheckoutSessions.create_session_for_booking(meeting)

      refute BookingPaymentQueries.by_meeting_id(meeting.id)
    end

    test "stripe_locale/1 maps known locales and falls back to auto" do
      assert CheckoutSessions.stripe_locale(nil) == "auto"
      assert CheckoutSessions.stripe_locale("uk") == "auto"
      assert CheckoutSessions.stripe_locale("en") == "en"
      assert CheckoutSessions.stripe_locale("de") == "de"
      assert CheckoutSessions.stripe_locale("fr") == "fr"
      assert CheckoutSessions.stripe_locale("it") == "it"
    end
  end
end
