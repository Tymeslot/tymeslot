defmodule Tymeslot.Emails.Delivery do
  @moduledoc """
  Email delivery infrastructure — circuit breaker, retry logic, and validation.

  All `send_*` functions in `Tymeslot.Emails.EmailService` delegate to
  `deliver/1` here once they have built a `Swoosh.Email` struct.
  """

  require Logger

  alias Tymeslot.Infrastructure.{CircuitBreaker, Retry}
  alias Tymeslot.Mailer

  @doc """
  Delivers an email using the configured mailer with circuit breaker and retry logic.
  """
  @spec deliver(Swoosh.Email.t()) :: {:ok, any()} | {:error, any()}
  def deliver(email) do
    with :ok <- check_text_body(email) do
      Logger.debug("Delivering email via Mailer",
        to: email.to,
        subject: email.subject
      )

      # Use circuit breaker with retry logic for email delivery
      CircuitBreaker.call(:email_service_breaker, fn ->
        Retry.with_backoff(
          fn -> do_deliver(email) end,
          max_attempts: 3,
          initial_delay: 1000,
          max_delay: 10_000,
          retriable?: &email_retriable?/1
        )
      end)
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

      {:error, reason} = error ->
        Logger.error("Failed to deliver email",
          to: email.to,
          subject: email.subject,
          reason: reason
        )

        error
    end
  end

  # Determine if an email error is retriable
  defp email_retriable?(reason) when is_binary(reason) do
    retriable_patterns = [
      "timeout",
      "connection refused",
      "network",
      "temporarily unavailable",
      "rate limit",
      "500",
      "502",
      "503",
      "504"
    ]

    down = String.downcase(reason)
    Enum.any?(retriable_patterns, fn pattern -> String.contains?(down, pattern) end)
  end

  defp email_retriable?(%{status: code}) when code in [500, 502, 503, 504] do
    true
  end

  defp email_retriable?(:timeout), do: true
  defp email_retriable?(:closed), do: true
  defp email_retriable?(:econnrefused), do: true
  defp email_retriable?(_error), do: false

  defp check_text_body(%Swoosh.Email{text_body: body, subject: subject}) when body in [nil, ""] do
    Logger.error("Refusing to deliver email without a plain-text body",
      subject: subject
    )

    {:error, {:missing_text_body, subject}}
  end

  defp check_text_body(%Swoosh.Email{}), do: :ok
end
