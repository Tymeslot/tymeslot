defmodule Tymeslot.Emails.Delivery do
  @moduledoc """
  Email delivery infrastructure — circuit breaker, retry logic, and validation.

  All `send_*` functions in `Tymeslot.Emails.EmailService` delegate to
  `deliver/1` here once they have built a `Swoosh.Email` struct.
  """

  require Logger

  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Mailer

  # Postmark reports an API-level rejection as `{422, %{"ErrorCode" => code}}`.
  # 300 (invalid email address) and 406 (inactive recipient — a prior hard
  # bounce, spam complaint, or manual suppression) can never succeed on retry.
  # Server, auth, and configuration codes are deliberately excluded so genuine
  # operational problems still surface as retryable failures.
  @permanent_rejection_codes [300, 406]

  # The SMTP counterpart: RFC 3463 enhanced status codes that describe the
  # address itself (bad mailbox, bad domain, bad syntax, domain accepts no
  # mail, mailbox disabled). Reply codes alone cannot be used: a 550 or 553
  # equally means "relaying denied" or "sender not owned", which are
  # configuration problems every email hits.
  @smtp_permanent_rejection ~r/\b5\.1\.(1|2|3|10)\b|\b5\.2\.1\b/

  # gen_smtp waits a fixed 20 minutes for each reply once connected, and Oban
  # workers kill a send that outlives their own budget from the outside,
  # where neither the breaker nor the retry policy sees it. Bounding the send
  # here, inside the breaker and below `EmailWorker`'s 30 seconds, turns a
  # hung relay into an ordinary timeout. It must stay above
  # `Tymeslot.Mailer.SMTPAdapter`'s 15-second session deadline, which is what
  # reports a relay that hung before any message data was sent as retryable.
  @default_send_deadline_ms 20_000

  @doc """
  Delivers an email using the configured mailer, wrapped in a circuit breaker.

  Retries are delegated to Oban (a single retry authority) rather than retried
  here — re-sending the same message on a flaky transport is what produces
  duplicate emails. A client-side timeout is treated as delivered for the same
  reason (see `timeout_error?/1`).

  Returns `{:error, {:recipient_rejected, reason}}` when the provider rejects
  the address permanently; callers should give up rather than retry.
  """
  @spec deliver(Swoosh.Email.t()) :: {:ok, any()} | {:error, any()}
  def deliver(email) do
    with :ok <- check_text_body(email) do
      Logger.debug("Delivering email via Mailer",
        to: email.to,
        subject: email.subject
      )

      CircuitBreaker.call(
        CircuitBreakerSupervisor.email_breaker_name(),
        fn -> email |> deliver_within_deadline() |> handle_delivery_result(email) end,
        classify: &classify_outcome/1
      )
    end
  end

  # `BreakerOutcome`'s default classifier only recognises a narrow set of
  # transport/HTTP error shapes; Tymeslot supports several mail adapters
  # (Postmark, SendGrid, Mailgun, AhaSend, SMTP) whose error reasons don't
  # share one shape (Postmark's is a bare `{status, body}`, not the
  # `{:http_error, status, body}` tuple the default classifier looks for).
  # `handle_delivery_error/2` already sorts every failure into permanent/timeout/transient
  # via `classify/1` before it gets here, so that triage is reused directly
  # instead of guessing again from the raw reason.
  defp classify_outcome({:error, {:recipient_rejected, _reason}}), do: :ignore
  defp classify_outcome({:error, _reason}), do: :failure
  # A client-side timeout is reported to the caller as `:assumed_delivered`
  # (see `handle_delivery_error/3` below) so a retry doesn't duplicate a mail
  # that likely already went out, but it is still evidence the provider is
  # unhealthy — a hung connection is the common shape of an SMTP/API outage,
  # so it must count as a breaker failure or the breaker never opens for it.
  defp classify_outcome({:ok, :assumed_delivered}), do: :failure
  defp classify_outcome(_other), do: :success

  # The adapter runs in its own process so the deadline can stop it: the
  # socket belongs to that process and closes with it. Unlinked, so an
  # adapter crash comes back here as an exit to re-raise rather than killing
  # the caller before the breaker has seen it.
  defp deliver_within_deadline(email) do
    deadline_ms = send_deadline_ms()
    task = Task.Supervisor.async_nolink(Tymeslot.TaskSupervisor, fn -> Mailer.deliver(email) end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, {exception, stacktrace}} when is_exception(exception) ->
        reraise exception, stacktrace

      {:exit, reason} ->
        exit(reason)

      nil ->
        {:error, {:send_deadline_exceeded, deadline_ms}}
    end
  end

  defp send_deadline_ms do
    Application.get_env(:tymeslot, :email_send_deadline_ms, @default_send_deadline_ms)
  end

  defp handle_delivery_result({:ok, _receipt} = result, email) do
    Logger.info("Email delivered successfully",
      to: email.to,
      subject: email.subject
    )

    result
  end

  defp handle_delivery_result({:error, reason}, email), do: handle_delivery_error(email, reason)

  defp handle_delivery_error(email, reason),
    do: handle_delivery_error(classify(reason), email, reason)

  # The provider has permanently rejected the address. Reported to the caller
  # as an error, but `BreakerOutcome.classify/1` leaves the breaker untouched
  # for it: a handful of suppressed addresses must not open a breaker that
  # blocks *all* outbound mail.
  defp handle_delivery_error(:permanent, email, reason) do
    Logger.warning("Email permanently undeliverable — recipient rejected by the provider",
      to: email.to,
      subject: email.subject,
      reason: inspect(reason)
    )

    {:error, {:recipient_rejected, reason}}
  end

  # A client-side timeout is ambiguous: the SMTP server has very likely already
  # accepted and sent the message, and only the client gave up waiting. Treating
  # it as a failure means a retry (here or via Oban) re-sends a message that was
  # already delivered — the root cause of duplicate emails. So we assume delivery
  # on timeout; a genuinely lost mail can be re-requested by the user.
  defp handle_delivery_error(:timeout, email, reason) do
    Logger.warning("Email delivery timed out; assuming delivered to avoid duplicate sends",
      to: email.to,
      subject: email.subject,
      reason: inspect(reason)
    )

    {:ok, :assumed_delivered}
  end

  defp handle_delivery_error(:transient, email, reason) do
    Logger.error("Failed to deliver email",
      to: email.to,
      subject: email.subject,
      reason: reason
    )

    {:error, reason}
  end

  defp classify(reason) do
    cond do
      permanent_rejection?(reason) -> :permanent
      timeout_error?(reason) -> :timeout
      true -> :transient
    end
  end

  @doc """
  Returns true when a delivery error reason is a permanent recipient rejection.

  A permanent rejection means the address itself is undeliverable — an invalid
  address, or one the provider has suppressed after a hard bounce or spam
  complaint. No number of retries can succeed, so callers should stop rather
  than back off.

  Accepts both the raw provider reason and the `{:recipient_rejected, reason}`
  tuple `deliver/1` returns, so it can be applied at either layer.
  """
  @spec permanent_rejection?(term()) :: boolean()
  def permanent_rejection?({422, %{"ErrorCode" => code}})
      when code in @permanent_rejection_codes,
      do: true

  def permanent_rejection?({:recipient_rejected, _reason}), do: true

  def permanent_rejection?({:send, {:permanent_failure, _host, message}}) when is_binary(message),
    do: message =~ @smtp_permanent_rejection

  def permanent_rejection?(_reason), do: false

  @doc """
  Returns true when a delivery error reason is a client-side timeout that may
  have happened after the message was handed over.

  Only such a timeout is ambiguous. gen_smtp reports failures while opening
  the session (connecting, greeting, TLS, authentication) as
  `{:retries_exceeded, _}` or `{:no_more_hosts, _}`, before any message data
  is sent, so a timeout there means the email certainly did not leave and
  must stay retryable. Treating it as delivered is how an unreachable relay
  silently swallowed every email.

  Other reason shapes are matched by inspecting the term, so new adapter
  error shapes don't silently slip through as retriable failures.
  """
  @spec timeout_error?(term()) :: boolean()
  def timeout_error?({phase, _failure}) when phase in [:retries_exceeded, :no_more_hosts],
    do: false

  def timeout_error?({:send_deadline_exceeded, _deadline_ms}), do: true

  def timeout_error?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> String.contains?("timeout")
  end

  defp check_text_body(%Swoosh.Email{text_body: body, subject: subject}) when body in [nil, ""] do
    Logger.error("Refusing to deliver email without a plain-text body",
      subject: subject
    )

    {:error, {:missing_text_body, subject}}
  end

  defp check_text_body(%Swoosh.Email{}), do: :ok
end
