defmodule Tymeslot.Workers.SendBookingPaymentRefundedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :payments

  import Swoosh.TestAssertions

  alias Ecto.UUID
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  # Swoosh's test adapter posts {:email, ...} to whichever process calls
  # Mailer.deliver/1, which is the CircuitBreaker GenServer — not the test
  # process. Pointing the adapter at this test collects the delivered emails
  # here instead, so the delivery branches can be told apart from the no-op
  # one. Safe because the module is `async: false`.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    :ok
  end

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

      assert_email_sent(fn email ->
        assert email.to == [{"Alice", "alice@example.com"}]
        assert email.subject == "Refund Issued - €50.00"
        assert email.text_body =~ "€50.00"
      end)
    end

    test "delivers a partial refund email when amounts differ" do
      payment = insert_payment(%{refunded_amount_cents: 2000, status: "partially_refunded"})

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        assert email.to == [{"Alice", "alice@example.com"}]
        assert email.subject == "Partial Refund Issued - €20.00"
        # The partial branch names the refunded amount against the original.
        assert email.text_body =~ "€20.00"
        assert email.text_body =~ "€50.00"
      end)
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

      refute_email_sent()
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

  describe "uniqueness" do
    test "second Oban.insert for the same booking_payment_id within 24 h is a conflict" do
      payment = insert_payment()
      args = %{"booking_payment_id" => payment.id}

      assert {:ok, %{conflict?: false}} = Oban.insert(SendBookingPaymentRefunded.new(args))
      assert {:ok, %{conflict?: true}} = Oban.insert(SendBookingPaymentRefunded.new(args))
    end
  end
end
