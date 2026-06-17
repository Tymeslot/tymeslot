defmodule Tymeslot.Emails.Delivery do
  @moduledoc """
  Email delivery infrastructure — circuit breaker, retry logic, and validation.

  All `send_*` functions in `Tymeslot.Emails.EmailService` delegate to
  `deliver/1` here once they have built a `Swoosh.Email` struct.
  """

  require Logger

  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Mailer

  @doc """
  Delivers an email using the configured mailer, wrapped in a circuit breaker.

  Retries are delegated to Oban (a single retry authority) rather than retried
  here — re-sending the same message on a flaky transport is what produces
  duplicate emails. A client-side timeout is treated as delivered for the same
  reason (see `do_deliver/1`).
  """
  @spec deliver(Swoosh.Email.t()) :: {:ok, any()} | {:error, any()}
  def deliver(email) do
    with :ok <- check_text_body(email) do
      Logger.debug("Delivering email via Mailer",
        to: email.to,
        subject: email.subject
      )

      CircuitBreaker.call(:email_service_breaker, fn -> do_deliver(email) end)
    end
  end

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

  # A client-side timeout is ambiguous: the SMTP server has very likely already
  # accepted and sent the message, and only the client gave up waiting. Treating
  # it as a failure means a retry (here or via Oban) re-sends a message that was
  # already delivered — the root cause of duplicate emails. So we assume delivery
  # on timeout; a genuinely lost mail can be re-requested by the user.
  defp handle_delivery_error(email, reason) do
    if timeout_error?(reason) do
      Logger.warning("Email delivery timed out; assuming delivered to avoid duplicate sends",
        to: email.to,
        subject: email.subject,
        reason: inspect(reason)
      )

      {:ok, :assumed_delivered}
    else
      Logger.error("Failed to deliver email",
        to: email.to,
        subject: email.subject,
        reason: reason
      )

      {:error, reason}
    end
  end

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
