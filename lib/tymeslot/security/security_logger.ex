defmodule Tymeslot.Security.SecurityLogger do
  @moduledoc """
  Security event logging for suspicious input patterns that were sanitised in place.

  ## Two sinks, and why `additional_data` looks unread

  Every event assembled here goes to two places, and they carry deliberately
  different amounts of detail.

  1. **Logger**, always. `log_security_event/2` forwards a fixed, canonical
     allowlist of flat keys and nothing else: `event_type`, `user_id`,
     `email_masked`, `ip_address`, `user_agent`, `session_id`, `provider`,
     `lockout_type`, `limit_type`. This is the log line an operator reads, and
     the allowlist is what keeps an event builder from widening it by accident.
  2. **An external monitoring webhook**, only when the operator opts in by
     setting `config :tymeslot, :security_monitoring_enabled, true` *and*
     `:security_monitoring_webhook`. It receives the same canonical keys plus
     `additional_data`.

  No shipped configuration sets `:security_monitoring_enabled`, so out of the
  box it is `false`, the webhook never fires, and the `additional_data` map the
  builders below assemble (`error_reason`, `oauth_state_valid`,
  `sessions_invalidated`, `failed_attempts`, `login_method`, …) reaches nothing.
  **That is the intended default, not an oversight.** Those fields are the
  richer detail an operator unlocks by pointing this at their own monitoring
  system; until they do, the canonical allowlist is the whole story, and the
  events carry masked emails and IP addresses, so turning the webhook on is a
  data-egress decision that belongs to the operator rather than to this module.

  Two consequences worth knowing before changing anything here:

  - **A field added to `additional_data` will not appear in the logs.** If it
    belongs on the log line, promote it into the canonical map instead.
  - **Promoting a key affects every event type, not just the one you had in
    mind**, because both sinks are built from one canonical map. `provider` is
    the cautionary tale: promoting it meant two input validators that happened
    to carry `params["provider"]` in their details map began writing raw user
    input to the log sink, which is why `sanitize_provider/1` exists. Grep
    every caller of `log_security_event/2` for the key first.
  """

  alias Tymeslot.Infrastructure.Config

  require Logger

  @type security_metadata :: %{
          optional(:ip) => String.t(),
          optional(:user_id) => integer(),
          optional(:user_agent) => String.t(),
          optional(atom()) => term()
        }

  @type event_metadata :: %{
          optional(:user_id) => integer(),
          optional(:ip_address) => String.t(),
          optional(:user_agent) => String.t(),
          optional(:session_id) => String.t(),
          optional(:additional_data) => map(),
          optional(atom()) => term()
        }

  @doc """
  Logs that suspicious input was sanitised in place.

  This function is purely informational. The caller (universal sanitiser) has
  already stripped the matching pattern from the value via `String.replace`
  and continues with the scrubbed string — nothing is rejected or aborted.
  The log line records that a heuristic fired so attack patterns can be
  monitored, not that a request was blocked.

  ## Parameters
  - `field` - The form/input field that matched (atom or string — e.g. `:name`, `:email`, `:message`)
  - `check` - Which detection rule fired (string — e.g. `"sql_injection"`, `"path_traversal"`, `"dangerous_protocol"`)
  - `metadata` - Additional context (map)

  ## Examples

      SecurityLogger.log_blocked_input(:email, "sql_injection", %{ip: "192.168.1.1"})
      SecurityLogger.log_blocked_input(:message, "dangerous_protocol", %{user_id: 123})

  The `field` is the specific form field whose value tripped the detection,
  not the detection rule itself. When debugging a false-positive log line you
  need both the form field (so you know where to look in the request) and
  the check (so you know which regex fired) — this function carries them as
  separate Logger metadata keys.
  """
  @spec log_blocked_input(atom() | String.t(), String.t(), security_metadata()) :: :ok
  def log_blocked_input(field, check, metadata \\ %{}) do
    sanitized_metadata = sanitize_metadata(metadata)

    Logger.warning("Suspicious input sanitised",
      field: field,
      check: check,
      ip_address: sanitized_metadata[:ip],
      user_id: sanitized_metadata[:user_id],
      user_agent: sanitized_metadata[:user_agent]
    )
  end

  # Private functions

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([:ip, :user_id, :user_agent])
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case sanitize_metadata_value(key, value) do
        nil -> acc
        sanitized_value -> Map.put(acc, key, sanitized_value)
      end
    end)
  end

  defp sanitize_metadata(_invalid), do: %{}

  defp sanitize_metadata_value(:ip, value) when is_binary(value) do
    # Basic IP validation - only log if it looks like a valid IP
    if Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, value) do
      value
    else
      nil
    end
  end

  defp sanitize_metadata_value(:user_id, value) when is_integer(value) and value > 0 do
    value
  end

  defp sanitize_metadata_value(:user_agent, value) when is_binary(value) do
    # Truncate user agent to prevent log injection
    value
    |> String.slice(0, 200)
    |> String.replace(~r/[\r\n\t]/, " ")
  end

  defp sanitize_metadata_value(_key, _value), do: nil

  # === EXISTING AUTHENTICATION LOGGING FUNCTIONS ===

  @doc """
  Logs a general security event with structured metadata.

  If `details[:email]` is present it is masked before logging so no raw
  email (PII) reaches Logger sinks or the monitoring webhook.

  Both sinks are derived from the same canonical detail map, so a key
  visible in the Logger line (`user_id`, `email_masked`, `ip_address`,
  `user_agent`, `session_id`, `provider`, `lockout_type`, `limit_type`) is
  never silently missing from the webhook payload. Raw identifiers are
  deliberately not among them — an event that needs to name an account puts
  it under `:email` so it is masked first. Anything an event builder
  assembles beyond the canonical set is carried to the webhook only, under
  `:additional_data`.
  """
  @spec log_security_event(String.t(), event_metadata()) :: :ok
  def log_security_event(event_type, details \\ %{}) do
    canonical = %{
      user_id: details[:user_id],
      email_masked: mask_email(details[:email]),
      ip_address: details[:ip_address],
      user_agent: details[:user_agent],
      session_id: details[:session_id],
      provider: sanitize_provider(details[:provider]),
      lockout_type: details[:lockout_type],
      limit_type: details[:limit_type]
    }

    Logger.info("Security event", [event_type: event_type] ++ Map.to_list(canonical))

    # Operator opt-in, off in every shipped configuration: no config file sets
    # this key. While it is false, `additional_data` has no sink at all — by
    # design, see the moduledoc. Do not "fix" that by widening the Logger
    # allowlist above without reading the caveats there first.
    if Application.get_env(:tymeslot, :security_monitoring_enabled, false) do
      send_to_monitoring_service(
        Map.merge(canonical, %{
          event_type: event_type,
          additional_data: details[:additional_data] || %{}
        })
      )
    end

    :ok
  end

  @doc """
  Masks an email so it is useful for correlating events without leaking
  the full address. `"john.doe@example.com"` becomes `"j***@example.com"`.
  Anything that isn't a parseable email is dropped entirely (`nil`), so a
  caller cannot pass a secret or a non-email identifier through unmasked.
  """
  @spec mask_email(term()) :: String.t() | nil
  def mask_email(nil), do: nil

  def mask_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() |> String.split("@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        "#{String.first(local)}***@#{domain}"

      _other ->
        nil
    end
  end

  def mask_email(_other), do: nil

  # `details[:provider]` sometimes carries raw, unvalidated user input (e.g.
  # a form's `params["provider"]`), not just the fixed OAuth provider atoms
  # this module's own callers use. Restrict it to a short identifier-shaped
  # value so an arbitrary attacker-controlled string can't ride into the log
  # line under this key; anything else is dropped rather than emitted.
  @spec sanitize_provider(term()) :: String.t() | nil
  defp sanitize_provider(nil), do: nil

  defp sanitize_provider(provider) when is_atom(provider), do: to_string(provider)

  defp sanitize_provider(provider) when is_binary(provider) do
    if Regex.match?(~r/^[a-zA-Z0-9_-]{1,32}$/, provider), do: provider, else: nil
  end

  defp sanitize_provider(_other), do: nil

  @doc """
  Logs authentication attempts with success/failure details.
  """
  @spec log_authentication_attempt(String.t(), boolean(), String.t() | nil, event_metadata()) ::
          :ok
  def log_authentication_attempt(email, success, reason \\ nil, metadata \\ %{}) do
    event_details = %{
      email: email,
      success: success,
      reason: reason,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        login_method: metadata[:login_method] || "email_password"
      }
    }

    event_type = if success, do: "authentication_success", else: "authentication_failure"
    log_security_event(event_type, event_details)
  end

  @doc """
  Logs session-related events (creation, deletion, validation).
  """
  @spec log_session_event(String.t(), integer(), String.t(), event_metadata()) :: :ok
  def log_session_event(event_type, user_id, session_id, metadata \\ %{}) do
    event_details = %{
      user_id: user_id,
      # Never log raw session tokens. Redact to last 8 chars.
      session_id: redact_session_id(session_id),
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: metadata[:additional_data] || %{}
    }

    log_security_event("session_#{event_type}", event_details)
  end

  # Redact sensitive session identifiers before logging
  defp redact_session_id(nil), do: nil

  defp redact_session_id(session_id) when is_binary(session_id) do
    if String.length(session_id) >= 8 do
      "…" <> String.slice(session_id, -8, 8)
    else
      "…REDACTED"
    end
  end

  defp redact_session_id(_invalid), do: nil

  @doc """
  Logs rate limiting violations.

  The identifier names the rejected attempt: an email address is carried
  under `:email` and masked before it reaches Logger, a user id under
  `:user_id` as-is. `nil` when the rejection identifies no account, which
  carries neither key.
  """
  @spec log_rate_limit_violation(String.t() | integer() | nil, String.t(), event_metadata()) ::
          :ok
  def log_rate_limit_violation(identifier, limit_type, metadata \\ %{}) do
    base_details = %{
      limit_type: limit_type,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        current_count: metadata[:current_count],
        limit: metadata[:limit],
        window_seconds: metadata[:window_seconds]
      }
    }

    event_details = Map.merge(base_details, rate_limit_identifier_details(identifier))

    log_security_event("rate_limit_violation", event_details)
  end

  # An email identifies the rejected attempt by account; a user id (e.g. the
  # email-verification path, which already has the user loaded) is not PII
  # and needs no masking.
  defp rate_limit_identifier_details(identifier) when is_integer(identifier),
    do: %{user_id: identifier}

  defp rate_limit_identifier_details(identifier) when is_binary(identifier),
    do: %{email: identifier}

  defp rate_limit_identifier_details(_identifier), do: %{}

  @doc """
  Logs account lockout events.

  The identifier is an email address, so it is carried under `:email` and
  masked before it reaches Logger.
  """
  @spec log_account_lockout(String.t(), String.t(), event_metadata()) :: :ok
  def log_account_lockout(identifier, lockout_type, metadata \\ %{}) do
    event_details = %{
      email: identifier,
      lockout_type: lockout_type,
      user_id: metadata[:user_id],
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        failed_attempts: metadata[:failed_attempts],
        lockout_duration_minutes: metadata[:lockout_duration_minutes]
      }
    }

    log_security_event("account_lockout", event_details)
  end

  @doc """
  Logs CSRF token validation failures for authentication forms.
  """
  @spec log_csrf_violation(integer() | nil, String.t(), event_metadata()) :: :ok
  def log_csrf_violation(user_id, action, metadata \\ %{}) do
    event_details = %{
      user_id: user_id,
      action: action,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        referer: metadata[:referer],
        origin: metadata[:origin]
      }
    }

    log_security_event("csrf_violation", event_details)
  end

  @doc """
  Logs password change events.
  """
  @spec log_password_change(integer(), event_metadata()) :: :ok
  def log_password_change(user_id, metadata \\ %{}) do
    event_details = %{
      user_id: user_id,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        sessions_invalidated: metadata[:sessions_invalidated] || false
      }
    }

    log_security_event("password_change", event_details)
  end

  @doc """
  Logs social authentication events.
  """
  @spec log_social_auth_event(String.t(), boolean(), event_metadata()) :: :ok
  def log_social_auth_event(provider, success, details \\ %{}) do
    event_type = if success, do: "social_auth_success", else: "social_auth_failure"

    event_details = %{
      provider: provider,
      success: success,
      email: details[:email],
      ip_address: details[:ip_address],
      user_agent: details[:user_agent],
      additional_data: %{
        oauth_state_valid: details[:oauth_state_valid],
        error_reason: details[:error_reason]
      }
    }

    log_security_event(event_type, event_details)
  end

  # Private helper functions for external monitoring

  # Security events fire hardest exactly when the system is under attack (a
  # credential-stuffing run produces one of these per request), so spawning
  # one task per event without a bound turns an auth flood into an unbounded
  # fan-out of outbound HTTP requests. This counter tracks only this module's
  # in-flight webhook deliveries, isolated from whatever else runs under the
  # shared `Tymeslot.TaskSupervisor`, and caps them.
  @max_concurrent_webhook_tasks 20
  @webhook_task_counter_key {__MODULE__, :webhook_task_counter}

  defp send_to_monitoring_service(metadata) do
    counter = webhook_task_counter()

    if :counters.get(counter, 1) >= @max_concurrent_webhook_tasks do
      Logger.warning("Security monitoring webhook fan-out at capacity, dropping event",
        event_type: metadata[:event_type]
      )

      :ok
    else
      :counters.add(counter, 1, 1)

      Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
        try do
          case Application.get_env(:tymeslot, :security_monitoring_webhook) do
            nil ->
              Logger.debug("Security monitoring webhook not configured")

            webhook_url ->
              send_webhook(webhook_url, metadata)
          end
        after
          :counters.sub(counter, 1, 1)
        end
      end)

      :ok
    end
  end

  defp webhook_task_counter do
    case :persistent_term.get(@webhook_task_counter_key, nil) do
      nil ->
        counter = :counters.new(1, [])
        :persistent_term.put(@webhook_task_counter_key, counter)
        counter

      counter ->
        counter
    end
  end

  defp send_webhook(webhook_url, metadata) do
    headers = [{"Content-Type", "application/json"}]
    body = Jason.encode!(metadata)

    case Config.http_client_module().post(webhook_url, body, headers,
           receive_timeout: 10_000,
           connect_options: [timeout: 5_000]
         ) do
      {:ok, %{status: status}} when status < 300 ->
        Logger.debug("Security event sent to monitoring service")

      {:ok, %{status: status}} ->
        Logger.warning("Failed to send security event to monitoring service", status: status)

      {:error, reason} ->
        Logger.error("Error sending security event to monitoring service", error: reason)
    end
  rescue
    error ->
      Logger.error("Exception sending security event to monitoring service",
        error: inspect(error)
      )
  end
end
