defmodule Tymeslot.Emails.Templates.AppointmentConfirmationPaymentTest do
  @moduledoc """
  Payment-specific tests for the appointment confirmation email — the receipt
  block on the attendee variant and the received-amount summary on the
  organiser variant.

  Kept in a separate file so the main confirmation test module stays under the
  Credo line-length cap.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :emails
  @moduletag :payments

  import Mox
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  import Tymeslot.EmailTestHelpers

  setup :verify_on_exit!

  describe "attendee payment receipt block" do
    test "renders payment block with receipt URL when charge fetch succeeds" do
      booking_payment = %{
        status: "paid",
        amount_cents: 5000,
        currency: "eur",
        application_fee_cents: 25,
        paid_at: ~U[2026-05-08 14:32:00Z],
        stripe_charge_id: "ch_TEST_RECEIPT",
        stripe_account_id: "acct_TEST"
      }

      expect(StripeAdapterMock, :retrieve_charge, fn "ch_TEST_RECEIPT", opts ->
        assert opts[:connect_account] == "acct_TEST"
        {:ok, %{receipt_url: "https://pay.stripe.com/receipts/r_TEST"}}
      end)

      details = build_appointment_details(%{booking_payment: booking_payment})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ "PAYMENT RECEIPT"
      assert email.text_body =~ "€50.00 paid"
      assert email.text_body =~ "ch_TEST_RECEIPT"
      assert email.text_body =~ "https://pay.stripe.com/receipts/r_TEST"
      assert email.html_body =~ "Payment receipt"
      assert email.html_body =~ "https://pay.stripe.com/receipts/r_TEST"
      assert email.html_body =~ "View receipt"
    end

    test "renders without payment block for free booking" do
      details = build_appointment_details(%{booking_payment: nil})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      refute email.text_body =~ "PAYMENT RECEIPT"
      refute email.html_body =~ "Payment receipt"
    end

    test "renders payment block without link when receipt fetch fails" do
      booking_payment = %{
        status: "paid",
        amount_cents: 5000,
        currency: "eur",
        application_fee_cents: 25,
        paid_at: ~U[2026-05-08 14:32:00Z],
        stripe_charge_id: "ch_TEST_FAIL",
        stripe_account_id: "acct_TEST"
      }

      expect(StripeAdapterMock, :retrieve_charge, fn _id, _opts -> {:error, :api_error} end)

      details = build_appointment_details(%{booking_payment: booking_payment})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ "PAYMENT RECEIPT"
      assert email.text_body =~ "€50.00 paid"
      refute email.text_body =~ "View receipt"
      assert email.html_body =~ "Payment receipt"
      refute email.html_body =~ "View receipt"
    end

    test "renders payment block without link when receipt URL is missing" do
      booking_payment = %{
        status: "paid",
        amount_cents: 5000,
        currency: "eur",
        application_fee_cents: 25,
        paid_at: ~U[2026-05-08 14:32:00Z],
        stripe_charge_id: "ch_TEST_NO_URL",
        stripe_account_id: "acct_TEST"
      }

      expect(StripeAdapterMock, :retrieve_charge, fn _id, _opts -> {:ok, %{receipt_url: nil}} end)

      details = build_appointment_details(%{booking_payment: booking_payment})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      refute email.html_body =~ "View receipt"
    end
  end

  describe "organizer received-amount block" do
    test "renders received-amount block for a paid booking" do
      booking_payment = %{
        status: "paid",
        amount_cents: 5000,
        currency: "eur",
        application_fee_cents: 25,
        paid_at: ~U[2026-05-08 14:32:00Z],
        stripe_charge_id: "ch_TEST_HOST",
        stripe_account_id: "acct_TEST"
      }

      details = build_appointment_details(%{booking_payment: booking_payment})
      email = AppointmentConfirmation.render(:organizer, "host@example.com", details)

      assert email.text_body =~ "PAYMENT RECEIVED"
      assert email.text_body =~ "You received €49.75"
      assert email.text_body =~ "Attendee paid:"
      assert email.text_body =~ "€50.00"
      assert email.text_body =~ "€0.25"
      assert email.text_body =~ "Funds will arrive on your usual Stripe payout schedule"

      assert email.html_body =~ "You received"
      assert email.html_body =~ "€49.75"
      assert email.html_body =~ "Tymeslot platform fee"
      assert email.html_body =~ "less Stripe processing fees"
    end

    test "omits received-amount block for free booking" do
      details = build_appointment_details(%{booking_payment: nil})
      email = AppointmentConfirmation.render(:organizer, "host@example.com", details)

      refute email.text_body =~ "PAYMENT RECEIVED"
      refute email.html_body =~ "Tymeslot platform fee"
    end

    test "block is English even when locale is non-English" do
      booking_payment = %{
        status: "paid",
        amount_cents: 10_000,
        currency: "eur",
        application_fee_cents: 50,
        paid_at: ~U[2026-05-08 14:32:00Z],
        stripe_charge_id: "ch_DE",
        stripe_account_id: "acct_DE"
      }

      details =
        build_appointment_details(%{
          booking_payment: booking_payment,
          attendee_locale: "de"
        })

      email = AppointmentConfirmation.render(:organizer, "host@example.com", details)

      # Host emails stay English regardless of attendee locale
      assert email.text_body =~ "You received"
      assert email.text_body =~ "Attendee paid"
      refute email.text_body =~ "Empfänger"
    end
  end
end
