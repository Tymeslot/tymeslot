defmodule Tymeslot.Auth.RateLimit do
  @moduledoc """
  The one place an auth flow turns a rate-limiter answer into an audited
  outcome.

  Every limited auth action does the same three things: ask the limiter,
  record a violation when it refuses, and hand the refusal back unchanged so
  the caller can show its message. Hand-rolling that per flow is how one of
  them ends up refusing without an audit entry, or auditing under the wrong
  name; routing every check through here keeps the gate whole.

  The context names the audit entry:

    * `:event` (required) - the `limit_type` the violation is logged under
    * `:identifier` - who the attempt concerns: an email (masked by the
      logger), a user id, or `nil` when there is no account to name
    * `:ip` and `:user_agent` - the request's origin, when known

  Bucket names, limits and messages all stay with `Tymeslot.Security.RateLimiter`;
  this module only decides what happens once it has answered.
  """

  alias Tymeslot.Security.SecurityLogger

  @type check_result :: :ok | {:error, :rate_limited, String.t()}

  @type context :: [
          event: String.t(),
          identifier: term(),
          ip: String.t() | nil,
          user_agent: String.t() | nil
        ]

  @doc """
  Passes `:ok` through, and logs a refusal as a rate-limit violation before
  returning it unchanged.
  """
  @spec check(check_result(), context()) :: check_result()
  def check(:ok, _context), do: :ok

  def check({:error, :rate_limited, _message} = refused, context) do
    SecurityLogger.log_rate_limit_violation(
      context[:identifier],
      Keyword.fetch!(context, :event),
      %{ip_address: context[:ip], user_agent: context[:user_agent]}
    )

    refused
  end

  @doc """
  Runs `fun` only when the limiter allowed the attempt; a refusal is logged
  (see `check/2`) and returned instead.
  """
  @spec with_limit(check_result(), context(), (-> result)) ::
          result | {:error, :rate_limited, String.t()}
        when result: term()
  def with_limit(result, context, fun) when is_function(fun, 0) do
    with :ok <- check(result, context), do: fun.()
  end
end
