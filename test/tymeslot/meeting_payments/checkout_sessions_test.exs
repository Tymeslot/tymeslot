defmodule Tymeslot.MeetingPayments.CheckoutSessionsTest do
  use Tymeslot.DataCase, async: true

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
        {:ok, %{id: "cs_TEST", url: "https://checkout.stripe.com/cs_TEST"}}
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

    test "rolls back booking_payment when Stripe Checkout fails",
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

      # No booking_payment row should exist after rollback
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
