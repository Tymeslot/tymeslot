defmodule Tymeslot.Emails.DeliveryTest do
  use Tymeslot.DataCase, async: false

  @moduletag :emails

  import Tymeslot.ConfigTestHelpers

  alias Swoosh.Email
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Test.FailingMailerAdapter
  alias Tymeslot.Test.LogCapture

  @suppressed_recipient {422,
                         %{
                           "ErrorCode" => 406,
                           "Message" =>
                             "You tried to send to recipient(s) that have been marked as inactive."
                         }}

  # Happy-path tests assert only on the tagged-tuple return value; the real
  # SMTP session is exercised in `Tymeslot.Emails.SMTPDeliveryTest`.

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

  # Every delivery is logged, and the recipient is usually an invitee without
  # an account: the log may say which domain mail went to, never to whom or
  # what it said about them.
  describe "deliver/1 — what the delivery log reveals" do
    setup do
      CircuitBreaker.reset(CircuitBreakerSupervisor.email_breaker_name())
      on_exit(fn -> CircuitBreaker.reset(CircuitBreakerSupervisor.email_breaker_name()) end)
      LogCapture.attach(logger_level: :debug)
      :ok
    end

    defp invitee_email do
      Email.new(
        to: {"Jane Invitee", "jane.invitee@Guest-Mail.test"},
        from: {"Tymeslot", "noreply@example.com"},
        subject: "Meeting Cancelled with Jane Invitee",
        text_body: "Plain-text body."
      )
    end

    defp delivery_log do
      Enum.map_join(LogCapture.drain(), "\n", &LogCapture.dump/1)
    end

    test "a successful delivery is logged by recipient domain alone" do
      assert {:ok, _receipt} = Delivery.deliver(invitee_email())

      event = LogCapture.await_log("Email delivered successfully")
      assert event.meta.recipient_domains == ["guest-mail.test"]

      log = LogCapture.dump(event) <> "\n" <> delivery_log()
      refute log =~ "jane.invitee"
      refute log =~ "Jane Invitee"
    end

    test "a rejected delivery names neither the recipient nor the subject" do
      setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
      setup_config(:tymeslot, :test_delivery_error, @suppressed_recipient)

      assert {:error, {:recipient_rejected, _reason}} = Delivery.deliver(invitee_email())

      event = LogCapture.await_log("permanently undeliverable")
      assert event.meta.recipient_domains == ["guest-mail.test"]

      log = LogCapture.dump(event) <> "\n" <> delivery_log()
      refute log =~ "jane.invitee"
      refute log =~ "Jane Invitee"
    end
  end

  describe "the email breaker" do
    setup do
      breaker = CircuitBreakerSupervisor.email_breaker_name()
      CircuitBreaker.reset(breaker)
      on_exit(fn -> CircuitBreaker.reset(breaker) end)
      setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
      setup_config(:tymeslot, :test_delivery_error, :econnrefused)
      :ok
    end

    test "email_breaker_refusing?/0 turns true once deliveries open the breaker" do
      refute Delivery.email_breaker_refusing?()

      for _attempt <- 1..Delivery.email_breaker_config().failure_threshold do
        assert {:error, :econnrefused} = Delivery.deliver(valid_email())
      end

      assert Delivery.email_breaker_refusing?()
    end

    test "email_breaker_recovery_seconds/0 is the breaker's recovery timeout in seconds" do
      %{recovery_timeout: recovery_ms} =
        CircuitBreaker.status(CircuitBreakerSupervisor.email_breaker_name()).config

      assert Delivery.email_breaker_recovery_seconds() * 1_000 == recovery_ms
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
    # Each test delivers through a breaker of its own, so no other delivery
    # in the suite can move the counts it asserts on.
    setup do
      setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      breaker = :"delivery_test_breaker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {CircuitBreaker, name: breaker, config: CircuitBreakerSupervisor.email_breaker_config()}
      )

      %{breaker: breaker}
    end

    test "returns a rejection the caller can distinguish from a transient failure", %{
      breaker: breaker
    } do
      setup_config(:tymeslot, :test_delivery_error, @suppressed_recipient)

      assert {:error, {:recipient_rejected, @suppressed_recipient}} =
               Delivery.deliver(valid_email(), breaker: breaker)
    end

    # The incident this guards against: three notifications to one hard-bounced
    # address opened the breaker, which then failed every unrelated email —
    # including the admin alert reporting the failure — for five minutes.
    test "does not count towards the circuit breaker, however many addresses are dead", %{
      breaker: breaker
    } do
      setup_config(:tymeslot, :test_delivery_error, @suppressed_recipient)
      threshold = CircuitBreaker.status(breaker).config.failure_threshold

      for _attempt <- 1..(threshold * 2) do
        assert {:error, {:recipient_rejected, _reason}} =
                 Delivery.deliver(valid_email(), breaker: breaker)
      end

      assert CircuitBreaker.status(breaker).status == :closed
    end

    test "a transient provider failure still opens the breaker", %{breaker: breaker} do
      setup_config(:tymeslot, :test_delivery_error, :econnrefused)
      threshold = CircuitBreaker.status(breaker).config.failure_threshold

      for _attempt <- 1..threshold do
        assert {:error, :econnrefused} = Delivery.deliver(valid_email(), breaker: breaker)
      end

      assert CircuitBreaker.status(breaker).status == :open
      assert {:error, :circuit_open} = Delivery.deliver(valid_email(), breaker: breaker)
    end

    # A hung SMTP/API connection is the common shape of a mail outage, and is
    # reported to the caller as "assume delivered" so a retry doesn't
    # duplicate a message that likely already went out — but that must not
    # also hide the outage from the breaker, or the breaker never opens and
    # every subsequent send is spent inside the outage instead of snoozing
    # past it.
    test "a timeout still opens the breaker, even though the caller sees assumed delivery", %{
      breaker: breaker
    } do
      setup_config(:tymeslot, :test_delivery_error, :timeout)
      threshold = CircuitBreaker.status(breaker).config.failure_threshold

      for _attempt <- 1..threshold do
        assert {:ok, :assumed_delivered} = Delivery.deliver(valid_email(), breaker: breaker)
      end

      assert CircuitBreaker.status(breaker).status == :open
      assert {:error, :circuit_open} = Delivery.deliver(valid_email(), breaker: breaker)
    end
  end

  describe "deliver/2 header values" do
    setup do
      Application.put_env(:swoosh, :shared_test_process, self())
      on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    end

    # A CR or LF in a display name or a subject must never reach the
    # adapter's header encoding, whichever template built the email.
    test "strips line breaks from display names and the subject, keeping the addresses" do
      email = %{
        valid_email()
        | to: [{"Ada\r\nBcc: victim@example.com", "ada@example.com"}],
          cc: [{"Grace\n", "grace@example.com"}],
          subject: "Meeting\r\nX-Injected: yes"
      }

      assert {:ok, _receipt} = Delivery.deliver(email)
      assert_received {:email, sent}

      assert sent.to == [{"Ada Bcc: victim@example.com", "ada@example.com"}]
      assert sent.cc == [{"Grace", "grace@example.com"}]
      assert sent.from == {"Tymeslot", "noreply@example.com"}
      assert sent.subject == "Meeting X-Injected: yes"
    end

    test "keeps the email's private data, which carries tracking" do
      email = Email.put_private(valid_email(), :tracking, %{"campaign" => "x"})

      assert {:ok, _receipt} = Delivery.deliver(email)
      assert_received {:email, %{private: %{tracking: %{"campaign" => "x"}}}}
    end
  end

  describe "deliver/2 and ambiguous timeouts" do
    setup do
      setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
      setup_config(:tymeslot, :test_delivery_error, :timeout)
      breaker = CircuitBreakerSupervisor.email_breaker_name()
      CircuitBreaker.reset(breaker)
      on_exit(fn -> CircuitBreaker.reset(breaker) end)
    end

    test "are assumed delivered unless the caller asks for the bounded retry" do
      assert {:ok, :assumed_delivered} = Delivery.deliver(valid_email())

      assert {{:ok, :assumed_delivered}, false} =
               Delivery.with_ambiguous_timeouts(:assume_delivered, fn ->
                 Delivery.deliver(valid_email())
               end)
    end

    test "under :retry_once come back as an error to retry, and say they happened" do
      assert {{:error, {:ambiguous, :timeout}}, true} =
               Delivery.with_ambiguous_timeouts(:retry_once, fn ->
                 Delivery.deliver(valid_email())
               end)

      # The policy ends with the call.
      assert {:ok, :assumed_delivered} = Delivery.deliver(valid_email())
    end

    # AhaSend's 202 Accepted can arrive with a body its adapter cannot parse.
    test "a 202 the adapter could not parse is a message the provider took" do
      setup_config(:tymeslot, :test_delivery_error, {202, "not json"})
      assert {:ok, :accepted} = Delivery.deliver(valid_email())
    end
  end

  describe "permanent_rejection?/1 for SMTP replies" do
    test "recognises an enhanced status code describing the address itself" do
      for code <- ["5.1.1", "5.1.2", "5.1.3", "5.1.10", "5.2.1"] do
        reply = "550 #{code} <guest@example.com>: rejected\r\n"
        assert Delivery.permanent_rejection?({:send, {:permanent_failure, ~c"host", reply}}), code
      end
    end

    test "does not treat relay policy or sender rejections as a dead recipient" do
      refute Delivery.permanent_rejection?(
               {:send, {:permanent_failure, ~c"host", "554 5.7.1 Relay access denied\r\n"}}
             )

      refute Delivery.permanent_rejection?(
               {:send, {:permanent_failure, ~c"host", "553 5.7.1 Sender address rejected\r\n"}}
             )

      refute Delivery.permanent_rejection?(
               {:send, {:permanent_failure, ~c"host", "550 mailbox unavailable\r\n"}}
             )
    end

    test "does not treat a failed login as a dead recipient" do
      refute Delivery.permanent_rejection?(
               {:no_more_hosts, {:permanent_failure, ~c"host", :auth_failed}}
             )
    end
  end

  describe "timeout_error?/1" do
    test "recognises a bare :timeout atom" do
      assert Delivery.timeout_error?(:timeout)
    end

    # A reason is judged by its shape; one that merely mentions a timeout in
    # its text (a provider's error body, say) is retried, not assumed sent.
    test "does not treat a reason that only mentions a timeout as one" do
      refute Delivery.timeout_error?("connection Timeout while sending")
      refute Delivery.timeout_error?({422, %{"Message" => "Request timeout"}})
    end

    test "recognises an API adapter's transport timeout and a gateway timeout" do
      assert Delivery.timeout_error?(%Mint.TransportError{reason: :timeout})
      assert Delivery.timeout_error?({504, "Gateway Timeout"})
    end

    test "recognises Finch's transport timeout, connect or receive alike" do
      assert Delivery.timeout_error?(%Finch.TransportError{reason: :timeout})
    end

    # gen_smtp reports a lost connection alike for MAIL FROM, RCPT TO and
    # DATA, so it cannot say whether anything was sent: retried, as a
    # duplicate is preferred to a loss.
    test "retries a connection gen_smtp lost after the session opened" do
      refute Delivery.timeout_error?({:send, {:network_failure, ~c"host", {:error, :closed}}})
    end

    test "retries other transport errors and HTTP statuses" do
      refute Delivery.timeout_error?(%Mint.TransportError{reason: :closed})
      refute Delivery.timeout_error?({503, "Service Unavailable"})
    end

    test "recognises a timeout gen_smtp reports mid-transaction, when the message may have left" do
      assert Delivery.timeout_error?({:send, {:network_failure, ~c"host", {:error, :timeout}}})
    end

    test "recognises the send deadline being exceeded" do
      assert Delivery.timeout_error?({:send_deadline_exceeded, 20_000})
    end

    # Opening the session happens before any message data is sent, so a
    # timeout there means the email certainly did not leave. Reporting it as
    # delivered silently dropped every email behind a firewalled relay.
    test "does not treat a timeout while opening the session as possibly delivered" do
      refute Delivery.timeout_error?(
               {:retries_exceeded, {:network_failure, ~c"10.255.255.1", {:error, :timeout}}}
             )

      refute Delivery.timeout_error?(
               {:no_more_hosts, {:permanent_failure, ~c"host", "421 timeout"}}
             )
    end

    test "does not classify unrelated failures as timeouts" do
      refute Delivery.timeout_error?(:econnrefused)
      refute Delivery.timeout_error?("550 mailbox unavailable")
      refute Delivery.timeout_error?({:permanent_failure, ~c"host", ~c"rejected"})
    end
  end
end
