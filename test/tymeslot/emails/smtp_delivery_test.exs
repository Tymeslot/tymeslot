defmodule Tymeslot.Emails.SMTPDeliveryTest do
  @moduledoc """
  Delivers through `Tymeslot.Mailer.SMTPAdapter` with the configuration
  `Tymeslot.Mailer.SMTPConfig` builds, against a scripted relay.

  Every defect this guards was invisible with the adapter mocked: gen_smtp's
  error shapes decide whether a failure is retried, reported delivered, or
  held against the circuit breaker, and only a real session produces them.
  """

  # async: false — the mailer configuration, the send deadline and the email
  # circuit breaker are all global.
  use ExUnit.Case, async: false

  @moduletag :emails
  @moduletag :mailer
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers

  alias Swoosh.Email
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Mailer.SMTPConfig
  alias Tymeslot.Test.FakeSmtpRelay

  setup do
    breaker = CircuitBreakerSupervisor.email_breaker_name()
    CircuitBreaker.reset(breaker)
    on_exit(fn -> CircuitBreaker.reset(breaker) end)

    %{breaker: breaker}
  end

  describe "a working relay" do
    test "delivers the message over an authenticated session" do
      relay = FakeSmtpRelay.start()
      use_relay(relay)

      assert {:ok, _receipt} = Delivery.deliver(email("Booking confirmed"))
      assert_receive {:smtp_relay, {:auth, _mechanism}}
      assert_receive {:smtp_relay, {:message, data}}
      assert data =~ "Subject: Booking confirmed"
    end

    test "delivers without logging in when no credentials are configured" do
      relay = FakeSmtpRelay.start()
      use_relay(relay, username: nil, password: nil)

      assert {:ok, _receipt} = Delivery.deliver(email("Unauthenticated relay"))
      assert_receive {:smtp_relay, {:message, data}}
      assert data =~ "Subject: Unauthenticated relay"
      refute_received {:smtp_relay, {:auth, _mechanism}}
    end
  end

  describe "a rejected login" do
    # With `auth: :if_available` gen_smtp shrugged off the 535 and sent the
    # message unauthenticated, so the operator saw the relay's 530 on MAIL
    # FROM instead of an authentication failure.
    test "fails as an authentication error without attempting the message" do
      relay = FakeSmtpRelay.start(auth: :reject)
      use_relay(relay)

      assert {:error, {:no_more_hosts, {:permanent_failure, _host, :auth_failed}}} =
               Delivery.deliver(email("Wrong password"))

      refute_received {:smtp_relay, {:mail_from, _line}}
    end
  end

  describe "a recipient the relay rejects" do
    @unknown_user "550 5.1.1 <guest@example.com>: Recipient address rejected: User unknown"

    test "is reported as a permanent rejection" do
      relay = FakeSmtpRelay.start(rcpt_reply: @unknown_user)
      use_relay(relay)

      assert {:error, {:recipient_rejected, {:send, {:permanent_failure, _host, message}}}} =
               Delivery.deliver(email("Dead address"))

      assert message =~ "5.1.1"
    end

    # Three dead guest addresses in a minute used to pause all mail for five
    # minutes.
    test "does not count towards the circuit breaker", %{breaker: breaker} do
      relay = FakeSmtpRelay.start(rcpt_reply: @unknown_user)
      use_relay(relay)
      threshold = CircuitBreaker.status(breaker).config.failure_threshold

      for _attempt <- 1..(threshold * 2) do
        assert {:error, {:recipient_rejected, _reason}} = Delivery.deliver(email("Dead address"))
      end

      assert CircuitBreaker.status(breaker).status == :closed
    end

    # A policy rejection says nothing about the address: every email would hit
    # it, so it must stay an ordinary, breaker-visible failure.
    test "stays a provider failure when the code is a relay policy", %{breaker: breaker} do
      relay = FakeSmtpRelay.start(rcpt_reply: "554 5.7.1 Relay access denied")
      use_relay(relay)

      assert {:error, {:send, {:permanent_failure, _host, _message}}} =
               Delivery.deliver(email("Relay denied"))

      assert CircuitBreaker.status(breaker).failure_count == 1
    end
  end

  describe "an unreachable relay" do
    test "returns a retryable error instead of assuming delivery" do
      use_relay(%{port: closed_port()})

      assert {:error, {:retries_exceeded, {:network_failure, _host, {:error, :econnrefused}}}} =
               Delivery.deliver(email("Nobody listening"))
    end
  end

  describe "a relay that stops answering" do
    # gen_smtp waits 20 minutes per reply. Before the session was opened under
    # its own deadline, a relay that never greeted was indistinguishable from
    # one that stalled mid-delivery, so it was reported delivered and the
    # email silently dropped.
    test "before the session opens, returns a retryable error", %{breaker: breaker} do
      relay = FakeSmtpRelay.start(greet: false)
      use_relay(relay, session_timeout: 200)

      assert {:error, {:retries_exceeded, {:network_failure, _host, {:error, :timeout}}}} =
               Delivery.deliver(email("Relay never greets"))

      assert CircuitBreaker.status(breaker).failure_count == 1
    end

    # Once the message is on the wire it may well have been delivered, so a
    # retry could duplicate it.
    test "after taking the message, is assumed delivered and counted against the breaker", %{
      breaker: breaker
    } do
      relay = FakeSmtpRelay.start(after_data: :silent)
      use_relay(relay)
      setup_config(:tymeslot, :email_send_deadline_ms, 500)

      assert {:ok, :assumed_delivered} = Delivery.deliver(email("Relay stalls after DATA"))
      assert_received {:smtp_relay, {:message, _data}}
      assert CircuitBreaker.status(breaker).failure_count == 1
    end
  end

  # `:session_timeout` is an adapter option, not an `SMTPConfig` one, so it is
  # layered onto the built configuration.
  defp use_relay(relay, overrides \\ []) do
    {adapter_overrides, build_overrides} = Keyword.split(overrides, [:session_timeout])

    config =
      [host: "localhost", port: relay.port, username: "user", password: "pass"]
      |> Keyword.merge(build_overrides)
      |> SMTPConfig.build()
      |> Keyword.merge(adapter_overrides)

    setup_config(:tymeslot, Tymeslot.Mailer, config)
  end

  defp email(subject) do
    Email.new(
      to: [{"Guest", "guest@example.com"}],
      from: {"Tymeslot", "noreply@example.com"},
      subject: subject,
      text_body: "Plain-text body.",
      html_body: "<p>HTML body.</p>"
    )
  end

  defp closed_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, {_address, port}} = :inet.sockname(listen)
    :gen_tcp.close(listen)
    port
  end
end
