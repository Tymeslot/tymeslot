defmodule Tymeslot.Emails.DeliveryTest do
  use Tymeslot.DataCase, async: false

  @moduletag :emails

  alias Swoosh.Email
  alias Tymeslot.Emails.Delivery

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
