defmodule Tymeslot.Workers.TransactionalEmailDeliveryTest do
  @moduledoc """
  The Stripe-triggered email workers call `Emails.Delivery` directly rather
  than going through `EmailWorker`, so they inherit Oban's default backoff:
  five attempts exhausted in roughly ninety seconds. The mail breaker stays
  open for five minutes, so every attempt of a refund, dispute or
  account-restricted email used to be spent inside the outage and the email
  then dropped for good.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :emails

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers

  alias Swoosh.Email
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Test.FailingMailerAdapter
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @suppressed_recipient {422,
                         %{
                           "ErrorCode" => 406,
                           "Message" => "You tried to send to recipient(s) marked as inactive."
                         }}

  setup do
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
    CircuitBreaker.reset(CircuitBreakerSupervisor.email_breaker_name())
    on_exit(fn -> CircuitBreaker.reset(CircuitBreakerSupervisor.email_breaker_name()) end)
    :ok
  end

  defp valid_email do
    Email.new(
      to: [{"Recipient", "recipient@example.com"}],
      from: {"Tymeslot", "noreply@example.com"},
      subject: "Test subject",
      text_body: "Plain-text body.",
      html_body: "<p>HTML body.</p>"
    )
  end

  defp open_the_breaker do
    setup_config(:tymeslot, :test_delivery_error, :econnrefused)
    breaker = CircuitBreakerSupervisor.email_breaker_name()
    threshold = CircuitBreaker.status(breaker).config.failure_threshold

    for _attempt <- 1..threshold do
      TransactionalEmailDelivery.deliver(valid_email(), "failed")
    end

    assert CircuitBreaker.status(breaker).status == :open
  end

  test "snoozes past the breaker's recovery window rather than retrying inside it" do
    open_the_breaker()

    assert {:snooze, seconds} = TransactionalEmailDelivery.deliver(valid_email(), "failed")

    assert seconds >= CircuitBreakerSupervisor.email_breaker_recovery_seconds()
  end

  # The bug this guards against: a snoozing job never closes the gap between
  # `attempt` and `max_attempts`, whichever of the two Oban moves, so nothing
  # ever stopped a job whose provider never recovers from snoozing forever — no
  # dead-letter, no admin alert, invisible to every queue monitor. `SnoozePolicy`
  # bounds it against the job's own execution count instead.
  describe "handle_failure/3 — bounded circuit-open snoozing" do
    test "keeps snoozing while under the bound" do
      assert {:snooze, _seconds} =
               TransactionalEmailDelivery.handle_failure(:circuit_open, "", executions: 1)

      assert {:snooze, _seconds} =
               TransactionalEmailDelivery.handle_failure(:circuit_open, "", executions: 11)
    end

    test "fails the job instead of snoozing once the bound is reached" do
      assert {:error, reason} =
               TransactionalEmailDelivery.handle_failure(:circuit_open, "", executions: 12)

      assert reason =~ "circuit breaker"
    end
  end

  test "discards an address the provider has permanently rejected" do
    setup_config(:tymeslot, :test_delivery_error, @suppressed_recipient)

    assert {:discard, "Recipient permanently undeliverable"} =
             TransactionalEmailDelivery.deliver(valid_email(), "failed")
  end

  # A discard emits Oban's `job:stop`, not `job:exception`, so it never
  # reaches `ObanFailureAlerter`. A rejected recipient — a host whose payouts
  # are restricted, or whose dispute email never arrives — must still surface
  # somewhere, so the rejection is reported directly instead.
  test "reports a permanently rejected recipient to AdminAlerts" do
    capture_admin_alerts()
    setup_config(:tymeslot, :test_delivery_error, @suppressed_recipient)

    assert {:discard, "Recipient permanently undeliverable"} =
             TransactionalEmailDelivery.deliver(valid_email(), "failed", booking_payment_id: 42)

    assert_receive {:send_alert, :recipient_email_rejected, payload}
    assert payload.booking_payment_id == 42
    assert payload.summary =~ "Recipient permanently undeliverable"
  end

  test "retries an ordinary transport failure" do
    setup_config(:tymeslot, :test_delivery_error, :econnrefused)

    assert {:error, :econnrefused} = TransactionalEmailDelivery.deliver(valid_email(), "failed")
  end

  test "returns :ok when the provider accepts the message" do
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Test)

    assert :ok = TransactionalEmailDelivery.deliver(valid_email(), "failed")
  end

  # `handle_failure/3` is also what `EmailWorker` calls for these three
  # reasons, so a rate limit means the same thing — a snooze, not a burned
  # attempt — everywhere in the email pipeline rather than only where the
  # job happens to carry an execution count.
  describe "handle_failure/3 for :rate_limited" do
    test "snoozes rather than retrying with an ordinary backoff" do
      assert {:snooze, seconds} = TransactionalEmailDelivery.handle_failure(:rate_limited, "", [])

      assert seconds > 0
    end

    test "scales the snooze with :executions when the caller supplies one" do
      assert {:snooze, 60} =
               TransactionalEmailDelivery.handle_failure(:rate_limited, "", executions: 1)

      assert {:snooze, 300} =
               TransactionalEmailDelivery.handle_failure(:rate_limited, "", executions: 5)
    end
  end
end
