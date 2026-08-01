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

  @doc """
  Delivers an email using the configured mailer, wrapped in a circuit breaker.

  Retries are delegated to Oban (a single retry authority) rather than retried
  here — re-sending the same message on a flaky transport is what produces
  duplicate emails. A client-side timeout is treated as delivered for the same
  reason (see `do_deliver/1`).

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

      CircuitBreakerSupervisor.email_breaker_name()
      |> CircuitBreaker.call(fn -> do_deliver(email) end)
      |> restore_rejection()
    end
  end

  # A permanent recipient rejection is a completed round-trip to the provider:
  # the API answered, and the answer was "this address is dead". Letting the
  # breaker count that as a failure means a handful of suppressed addresses can
  # open it and block *all* outbound mail, so `do_deliver/1` hands the breaker a
  # success and the rejection is turned back into an error out here, where the
  # breaker can no longer see it.
  defp restore_rejection({:ok, {:recipient_rejected, _reason} = rejection}),
    do: {:error, rejection}

  defp restore_rejection(result), do: result

  defp do_deliver(email) do
    case Mailer.deliver(email) do
      {:ok, _email} = result ->
        Logger.info("Email delivered successfully",
          to: email.to,
          subject: email.subject
        )

        result

      {:error, reason} ->
        handle_delivery_error(email, reason)
    end
  end

  defp handle_delivery_error(email, reason),
    do: handle_delivery_error(classify(reason), email, reason)

  # The provider has permanently rejected the address. Reported as a success to
  # the breaker (see `restore_rejection/1`) and unwrapped back into an error by
  # `deliver/1`.
  defp handle_delivery_error(:permanent, email, reason) do
    Logger.warning("Email permanently undeliverable — recipient rejected by the provider",
      to: email.to,
      subject: email.subject,
      reason: inspect(reason)
    )

    {:ok, {:recipient_rejected, reason}}
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
  def permanent_rejection?(_reason), do: false

  @doc """
  Returns true when a delivery error reason represents a (client-side) timeout.

  Matches any reason shape — bare `:timeout`, a string mentioning "timeout", or
  the nested tuples gen_smtp produces — by inspecting the term, so new adapter
  error shapes don't silently slip through as retriable failures.
  """
  @spec timeout_error?(term()) :: boolean()
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
