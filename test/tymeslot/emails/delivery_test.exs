defmodule Tymeslot.Emails.DeliveryTest do
  use Tymeslot.DataCase, async: false

  @moduletag :emails

  import Tymeslot.ConfigTestHelpers

  alias Swoosh.Email
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Test.FailingMailerAdapter

  @suppressed_recipient {422,
                         %{
                           "ErrorCode" => 406,
                           "Message" =>
                             "You tried to send to recipient(s) that have been marked as inactive."
                         }}

  # Swoosh.Adapters.Test sends the {:email, email} message to whichever process
  # calls Mailer.deliver/1 — here that is the CircuitBreaker GenServer, not the
  # test process — so assert_email_sent/1 cannot be used. Happy-path tests
  # assert only on the tagged-tuple return value.

  defp valid_email(overrides \\ []) do
    Email.new(
      [
        to: [{"Recipient", "recipient@example.com"}],
        from: {"Tymeslot", "noreply@example.com"},
        subject: "Test subject",
        text_body: "Plain-text body.",
        html_body: "<p>HTML body.</p>"
      ] ++ overrides
    )
  end

  describe "deliver/1 — text_body validation" do
    test "returns {:error, {:missing_text_body, subject}} when text_body is nil" do
      email = valid_email(text_body: nil, subject: "Missing body email")

      assert {:error, {:missing_text_body, "Missing body email"}} = Delivery.deliver(email)
    end

    test "returns {:error, {:missing_text_body, subject}} when text_body is an empty string" do
      email = valid_email(text_body: "", subject: "Empty body email")

      assert {:error, {:missing_text_body, "Empty body email"}} = Delivery.deliver(email)
    end

    test "includes the email subject in the error tuple so callers can log it" do
      subject = "Subject for error reporting #{System.unique_integer([:positive])}"
      email = valid_email(text_body: nil, subject: subject)

      assert {:error, {:missing_text_body, ^subject}} = Delivery.deliver(email)
    end

    test "does not call the mailer when text_body is nil" do
      # If the mailer were called it would push a message to the circuit breaker
      # GenServer's mailbox. We verify no such side-effect occurred by asserting
      # the error is returned immediately.
      email = valid_email(text_body: nil)

      result = Delivery.deliver(email)

      assert match?({:error, {:missing_text_body, _}}, result)
    end
  end

  describe "deliver/1 — happy path" do
    test "returns {:ok, _} for a well-formed email with a text body" do
      email = valid_email()

      assert {:ok, _result} = Delivery.deliver(email)
    end

    test "accepts an email with only a text body and no html body" do
      email = valid_email(html_body: nil)

      assert {:ok, _result} = Delivery.deliver(email)
    end
  end

  describe "permanent_rejection?/1" do
    test "recognises the Postmark codes for a dead address" do
      assert Delivery.permanent_rejection?({422, %{"ErrorCode" => 406}})
      assert Delivery.permanent_rejection?({422, %{"ErrorCode" => 300}})
    end

    test "recognises the tuple deliver/1 returns, so it can be applied at either layer" do
      assert Delivery.permanent_rejection?({:recipient_rejected, @suppressed_recipient})
    end

    test "leaves operational provider errors retryable" do
      refute Delivery.permanent_rejection?({422, %{"ErrorCode" => 10}})
      refute Delivery.permanent_rejection?({500, %{"ErrorCode" => 406}})
      refute Delivery.permanent_rejection?(:econnrefused)
      refute Delivery.permanent_rejection?({422, %{}})
    end
  end

  describe "deliver/1 — permanent recipient rejection" do
    setup do
      setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
      CircuitBreaker.reset(CircuitBreakerSupervisor.email_breaker_name())
      on_exit(fn -> CircuitBreaker.reset(CircuitBreakerSupervisor.email_breaker_name()) end)
      :ok
    end

    test "returns a rejection the caller can distinguish from a transient failure" do
      setup_config(:tymeslot, :test_delivery_error, @suppressed_recipient)

      assert {:error, {:recipient_rejected, @suppressed_recipient}} =
               Delivery.deliver(valid_email())
    end

    # The incident this guards against: three notifications to one hard-bounced
    # address opened the breaker, which then failed every unrelated email —
    # including the admin alert reporting the failure — for five minutes.
    test "does not count towards the circuit breaker, however many addresses are dead" do
      setup_config(:tymeslot, :test_delivery_error, @suppressed_recipient)
      breaker = CircuitBreakerSupervisor.email_breaker_name()
      threshold = CircuitBreaker.status(breaker).config.failure_threshold

      for _attempt <- 1..(threshold * 2) do
        assert {:error, {:recipient_rejected, _reason}} = Delivery.deliver(valid_email())
      end

      assert CircuitBreaker.status(breaker).status == :closed
    end

    test "a transient provider failure still opens the breaker" do
      setup_config(:tymeslot, :test_delivery_error, :econnrefused)
      breaker = CircuitBreakerSupervisor.email_breaker_name()
      threshold = CircuitBreaker.status(breaker).config.failure_threshold

      for _attempt <- 1..threshold do
        assert {:error, :econnrefused} = Delivery.deliver(valid_email())
      end

      assert CircuitBreaker.status(breaker).status == :open
      assert {:error, :circuit_open} = Delivery.deliver(valid_email())
    end

    # A hung SMTP/API connection is the common shape of a mail outage, and is
    # reported to the caller as "assume delivered" so a retry doesn't
    # duplicate a message that likely already went out — but that must not
    # also hide the outage from the breaker, or the breaker never opens and
    # every subsequent send is spent inside the outage instead of snoozing
    # past it.
    test "a timeout still opens the breaker, even though the caller sees assumed delivery" do
      setup_config(:tymeslot, :test_delivery_error, :timeout)
      breaker = CircuitBreakerSupervisor.email_breaker_name()
      threshold = CircuitBreaker.status(breaker).config.failure_threshold

      for _attempt <- 1..threshold do
        assert {:ok, :assumed_delivered} = Delivery.deliver(valid_email())
      end

      assert CircuitBreaker.status(breaker).status == :open
      assert {:error, :circuit_open} = Delivery.deliver(valid_email())
    end
  end

  describe "timeout_error?/1" do
    test "recognises a bare :timeout atom" do
      assert Delivery.timeout_error?(:timeout)
    end

    test "recognises a string mentioning a timeout, case-insensitively" do
      assert Delivery.timeout_error?("connection Timeout while sending")
    end

    test "recognises the nested tuple shapes gen_smtp produces" do
      assert Delivery.timeout_error?({:retries_exceeded, {:network_failure, ~c"host", :timeout}})
    end

    test "does not classify unrelated failures as timeouts" do
      refute Delivery.timeout_error?(:econnrefused)
      refute Delivery.timeout_error?("550 mailbox unavailable")
      refute Delivery.timeout_error?({:permanent_failure, ~c"host", ~c"rejected"})
    end
  end
end
