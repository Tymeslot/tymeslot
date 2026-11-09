defmodule Tymeslot.Mailer.SMTPResult do
  @moduledoc """
  Interprets SMTP outcomes without returning relay replies or account secrets.

  Enhanced status codes identify permanent destination failures. A generic
  550/553 can instead reject the sender or relay permission, so it must remain
  retryable rather than suppressing every recipient of a misconfigured account.
  """

  @permanent_recipient ~r/\b5\.1\.(1|2|3|10)\b|\b5\.2\.1\b/

  @type failure ::
          :recipient_rejected
          | :authentication_failed
          | :tls_required
          | :session_timeout
          | :ambiguous_timeout
          | :delivery_failed

  @doc "Whether a raw SMTP transaction permanently rejected its destination."
  @spec permanent_rejection?(term()) :: boolean()
  def permanent_rejection?({:send, {:permanent_failure, _host, message}})
      when is_binary(message),
      do: message =~ @permanent_recipient

  def permanent_rejection?(_reason), do: false

  @doc "Reduces an SMTP error to a safe category, preserving delivery ambiguity."
  @spec classify(term()) :: failure()
  def classify({:retries_exceeded, {:missing_requirement, _host, :auth}}),
    do: :authentication_failed

  def classify({:no_more_hosts, {:permanent_failure, _host, :auth_failed}}),
    do: :authentication_failed

  def classify({:retries_exceeded, {:missing_requirement, _host, :tls}}),
    do: :tls_required

  def classify({:retries_exceeded, {:network_failure, _host, {:error, :timeout}}}),
    do: :session_timeout

  def classify({:send, {:network_failure, _host, {:error, :timeout}}}),
    do: :ambiguous_timeout

  def classify(:timeout), do: :ambiguous_timeout

  def classify(reason) do
    if permanent_rejection?(reason), do: :recipient_rejected, else: :delivery_failed
  end
end
