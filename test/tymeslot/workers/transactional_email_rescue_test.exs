defmodule Tymeslot.Workers.TransactionalEmailRescueTest do
  @moduledoc """
  A job the Oban lifeline rescues is the same job run a second time, after
  its first run already sent the email. Each Stripe-triggered email worker
  must send once however many times that happens.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :payments

  import Swoosh.TestAssertions
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Workers.SendBookingPaymentRefunded
  alias Tymeslot.Workers.SendChargeDisputeOpened
  alias Tymeslot.Workers.SendConnectAccountRestricted

  # Delivery runs inside the mail CircuitBreaker, not the test process, so the
  # Swoosh test adapter is pointed here to collect what was actually sent.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    :ok
  end

  defp insert_payment(attrs) do
    defaults = %{
      attendee_email: "alice@example.com",
      attendee_name: "Alice",
      host_email: "host@example.com",
      host_name: "Bob Host",
      meeting_type_name: "Discovery Call",
      amount_cents: 5000,
      currency: "eur",
      stripe_account_id: "acct_TEST",
      paid_at: DateTime.utc_now(:second)
    }

    insert(:booking_payment, Map.merge(defaults, attrs))
  end

  defp run_twice(worker, job) do
    assert :ok = worker.perform(job)
    assert :ok = worker.perform(job)
  end

  test "SendBookingPaymentRefunded sends the refund email once across a rescue" do
    payment = insert_payment(%{refunded_amount_cents: 5000, status: "refunded"})

    job = persisted_job(SendBookingPaymentRefunded, %{"booking_payment_id" => payment.id})
    run_twice(SendBookingPaymentRefunded, job)

    assert_email_sent(to: [{"Alice", "alice@example.com"}])
    refute_email_sent()
  end

  test "SendChargeDisputeOpened sends the dispute email once across a rescue" do
    payment =
      insert_payment(%{status: "disputed", stripe_charge_id: "ch_DISPUTED"})

    job =
      persisted_job(SendChargeDisputeOpened, %{
        "booking_payment_id" => payment.id,
        "reason" => "fraudulent"
      })

    run_twice(SendChargeDisputeOpened, job)

    assert_email_sent(fn email -> assert [{_name, "host@example.com"}] = email.to end)
    refute_email_sent()
  end

  test "SendConnectAccountRestricted sends the restriction email once across a rescue" do
    user = insert(:user, email: "host@example.com", name: "Bob Host")

    account =
      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_RESTRICTED",
        country: "ch",
        default_currency: "chf",
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: true,
        disabled_reason: "requirements.past_due",
        status: "active"
      )

    job =
      persisted_job(SendConnectAccountRestricted, %{
        "connect_account_id" => account.id,
        "disabled_reason" => "requirements.past_due"
      })

    run_twice(SendConnectAccountRestricted, job)

    assert_email_sent(fn email -> assert [{_name, "host@example.com"}] = email.to end)
    refute_email_sent()
  end
end
