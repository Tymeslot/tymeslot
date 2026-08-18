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

  test "discards an address the provider has permanently rejected" do
    setup_config(:tymeslot, :test_delivery_error, @suppressed_recipient)

    assert {:discard, "Recipient permanently undeliverable"} =
             TransactionalEmailDelivery.deliver(valid_email(), "failed")
  end

  test "retries an ordinary transport failure" do
    setup_config(:tymeslot, :test_delivery_error, :econnrefused)

    assert {:error, :econnrefused} = TransactionalEmailDelivery.deliver(valid_email(), "failed")
  end

  test "returns :ok when the provider accepts the message" do
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Test)

    assert :ok = TransactionalEmailDelivery.deliver(valid_email(), "failed")
  end
end
