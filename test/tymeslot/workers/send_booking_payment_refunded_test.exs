defmodule Tymeslot.Workers.SendBookingPaymentRefundedTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :payments

  alias Ecto.UUID
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  # Swoosh's test adapter posts {:email, ...} to whichever process calls
  # Mailer.deliver/1, which is the CircuitBreaker GenServer — not the test
  # process. Worker tests therefore rely on the worker's return value;
  # rendering correctness is tested directly in the template test suite.

  defp insert_payment(attrs \\ %{}) do
    defaults = %{
      attendee_email: "alice@example.com",
      attendee_name: "Alice",
      host_name: "Bob Host",
      meeting_type_name: "Discovery Call",
      amount_cents: 5000,
      refunded_amount_cents: 5000,
      currency: "eur",
      status: "refunded",
      stripe_account_id: "acct_TEST",
      paid_at: DateTime.utc_now(:second)
    }

    insert(:booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  describe "perform/1" do
    test "delivers a refund email for a fully-refunded booking" do
      payment = insert_payment()

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })
    end

    test "delivers a partial refund email when amounts differ" do
      payment = insert_payment(%{refunded_amount_cents: 2000, status: "partially_refunded"})

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })
    end

    test "discards when booking_payment is missing" do
      assert {:discard, "booking_payment not found"} =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => UUID.generate()
               })
    end

    test "no-ops when refunded_amount_cents is zero" do
      payment = insert_payment(%{refunded_amount_cents: 0, status: "paid"})

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })
    end

    test "discards when booking_payment_id is missing from args" do
      assert {:discard, "missing booking_payment_id"} =
               perform_job(SendBookingPaymentRefunded, %{})
    end

    test "discards when attendee_email has been anonymised to nil" do
      payment = insert_payment(%{attendee_email: nil})

      assert {:discard, "missing attendee_email"} =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })
    end
  end
end
