defmodule Tymeslot.Infrastructure.BreakerOutcome do
  @moduledoc """
  Decides what a call's result says about the *provider's* health.

  A circuit breaker exists to stop hammering a service that is down. That makes
  the only question it needs answered "is the remote side unwell?", which is a
  narrower question than "did this call fail?". A rejected OAuth grant, a
  missing scope, a 404, a changeset error: all of these are failures, and none
  of them is evidence that the provider is unavailable. Counting them as
  outages opens a breaker that is shared by every tenant, so one user's bad
  credentials stop everyone else's calls.

  Hence three outcomes rather than two:

  - `:failure` - the provider looks unwell (transport errors, 5xx, 429, and
    anything a caller explicitly tags `{:provider_error, reason}`).
  - `:success` - the call worked.
  - `:ignore` - the call failed, but for a reason local to us or specific to
    this tenant's data. Breaker state is left completely untouched: it neither
    trips nor counts towards closing a half-open breaker.

  The `{:provider_error, reason}` tag is the deliberate escape hatch, and the
  video providers already use it: `ZoomProvider.classify_token_result/1` hands
  back a plain `{:error, _}` for a rejected grant and `{:provider_error, _}`
  for "anything else, for the breaker to witness". This module is where that
  convention is decided once, so a new provider inherits it instead of growing
  another copy.
  """

  @type outcome :: :success | :failure | :ignore

  # OAuth error markers that mean the credential itself is gone — a rejected
  # or expired grant, not the provider being unwell. Shared by every OAuth
  # video provider (Zoom, Teams, Google Meet) and by
  # `HealthCheck.ResponseHandler`'s reauth fast-path, which previously each
  # carried their own copy; the provider copies only matched strings, so a
  # bare atom reason (`:unauthorized`, `:invalid_credentials`,
  # `:token_expired`) fell through to `{:provider_error, _}` and tripped the
  # shared breaker instead of being recognised as the tenant's problem.
  #
  # String markers are matched against whole-word tokens extracted from the
  # lowercased error reason (split on non-alphanumeric/underscore
  # boundaries), which prevents `"invalid_grant"` from matching extended
  # forms such as `"invalid_grant_period_started"` and prevents
  # `"unauthorized"` false positives from strings like `"unauthorized
  # origin"` produced by CalDAV servers and Google JS-API errors — which is
  # also why the string list omits `"unauthorized"`: the atom form already
  # covers it without that risk.
  @permanent_credential_error_strings ~w(invalid_grant invalid_client access_denied)
  @permanent_credential_error_atoms [:unauthorized, :invalid_credentials, :token_expired]

  @doc """
  Whether `reason` describes a permanently rejected credential (an expired or
  revoked OAuth grant) rather than a provider outage.

  A caller that gets `true` back should surface this as a plain `{:error, _}`
  that bypasses the breaker entirely; the tenant needs to reconnect, and
  retrying or counting it against a shared breaker helps no one.
  """
  @spec permanent_credential_error?(term()) :: boolean()
  def permanent_credential_error?(reason) when is_atom(reason),
    do: reason in @permanent_credential_error_atoms

  def permanent_credential_error?(reason) when is_binary(reason),
    do: Enum.any?(@permanent_credential_error_strings, &(&1 in error_tokens(reason)))

  def permanent_credential_error?({:exception, message}) when is_binary(message),
    do: permanent_credential_error?(message)

  def permanent_credential_error?(_reason), do: false

  # Splits the reason into whole-word tokens for matching. Non-UTF-8 reasons
  # (some providers hand back raw bytes) tokenise to nothing rather than
  # blowing up `String.downcase/1`.
  defp error_tokens(reason) do
    if String.valid?(reason) do
      reason |> String.downcase() |> String.split(~r/[^a-z0-9_]+/, trim: true)
    else
      []
    end
  end

  # Reasons that describe the connection itself rather than the response.
  @transport_reasons ~w(
    timeout network_error closed econnrefused econnreset ehostunreach
    enetunreach etimedout nxdomain closed_by_peer socket_closed_remotely
  )a

  # Transport-level exception structs, matched by name so that neither Req nor
  # Mint has to be a compile-time dependency of this module.
  @transport_exceptions ~w(
    Elixir.Req.TransportError Elixir.Mint.TransportError Elixir.Mint.HTTPError
  )a

  @doc """
  Classifies a (normalised) call result.

  Anything unrecognised is treated as `:ignore` rather than `:failure`: an
  unclassified error is not evidence of an outage, and the cost of guessing
  wrong in that direction is a breaker that stays closed one call too long,
  against a breaker that opens for everyone on a local validation error.
  """
  @spec classify(term()) :: outcome()
  def classify(:ok), do: :success
  def classify({:ok, _result}), do: :success
  def classify({:provider_error, _reason}), do: :failure
  def classify({:error, reason}), do: classify_error(reason)
  # `execute_function/2` normalises bare values into `{:ok, _}`, so anything
  # still untagged here came from a caller reporting its own result.
  def classify(_other), do: :success

  # A breaker refusal from a nested call says nothing new about the provider,
  # and counting it would let an open breaker keep itself open.
  defp classify_error(:circuit_open), do: :ignore

  defp classify_error({:http_error, status, _body}), do: classify_status(status)
  defp classify_error({:http_error, status}), do: classify_status(status)

  defp classify_error(reason) when reason in @transport_reasons, do: :failure

  defp classify_error(%module{}) when module in @transport_exceptions, do: :failure

  # Everything else is ours or the tenant's: changeset errors, missing scopes,
  # rejected grants, not-found, misconfiguration.
  defp classify_error(_reason), do: :ignore

  # 429 and 5xx mean "the provider cannot serve this right now". 408 is a
  # timeout the provider reported about itself. Every other 4xx is a statement
  # about the request, not about the provider's health.
  defp classify_status(status) when is_integer(status) and status >= 500, do: :failure
  defp classify_status(429), do: :failure
  defp classify_status(408), do: :failure
  defp classify_status(status) when is_integer(status), do: :ignore
  defp classify_status(_status), do: :ignore
end
