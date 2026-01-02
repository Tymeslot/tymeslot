defmodule Tymeslot.Infrastructure.Security.Recaptcha do
  @moduledoc """
  reCAPTCHA v3 verification module for validating tokens.
  """

  require Logger

  @verify_url "https://www.google.com/recaptcha/api/siteverify"
  @default_minimum_score 0.3

  @doc """
  Verifies a reCAPTCHA token with Google's API.
  Returns {:ok, %{score: float}} on success or {:error, reason} on failure.
  """
  @type verify_opt ::
          {:min_score, float()}
          | {:expected_action, String.t() | nil}
          | {:expected_hostnames, [String.t()]}
          | {:remote_ip, String.t() | nil}

  @spec verify(String.t(), [verify_opt()]) ::
          {:ok, %{score: float(), action: String.t() | nil, hostname: String.t() | nil}}
          | {:error, atom()}
  def verify(token, opts \\ [])

  def verify(token, opts) when is_binary(token) and byte_size(token) > 0 do
    # Reject tokens that exceed 5KB (real reCAPTCHA tokens are ~500 bytes)
    # This prevents DoS attacks with huge token payloads
    if byte_size(token) > 5_000 do
      Logger.warning("reCAPTCHA token exceeds size limit (#{byte_size(token)} bytes)")
      {:error, :invalid_token}
    else
      case secret_key() do
        key when is_binary(key) and byte_size(key) > 0 ->
          verify_with_secret(token, key, opts)

        _ ->
          Logger.error("reCAPTCHA verification failed: missing or invalid secret key")
          {:error, :recaptcha_configuration_error}
      end
    end
  end

  @spec verify(any(), any()) :: {:error, :invalid_token}
  def verify(_, _), do: {:error, :invalid_token}

  defp verify_with_secret(token, secret_key, opts) do
    min_score = Keyword.get(opts, :min_score, @default_minimum_score)
    expected_action = Keyword.get(opts, :expected_action, nil)
    expected_hostnames = Keyword.get(opts, :expected_hostnames, [])
    remote_ip = Keyword.get(opts, :remote_ip, nil)

    body =
      %{
        "secret" => secret_key,
        "response" => token
      }
      |> maybe_put_remote_ip(remote_ip)
      |> URI.encode_query()

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case HTTPoison.post(@verify_url, body, headers, timeout: 5000, recv_timeout: 5000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        handle_verification_response(response_body, min_score, expected_action, expected_hostnames)

      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        Logger.error("reCAPTCHA verification failed with status: #{status_code}")
        {:error, :recaptcha_request_failed}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("reCAPTCHA verification request error: #{inspect(reason)}")
        {:error, :recaptcha_network_error}
    end
  end

  defp handle_verification_response(response_body, min_score, expected_action, expected_hostnames) do
    case Jason.decode(response_body) do
      {:ok, %{"success" => true, "score" => score} = decoded} when is_number(score) ->
        action = Map.get(decoded, "action")
        hostname = Map.get(decoded, "hostname")

        with :ok <- validate_min_score(score, min_score),
             :ok <- validate_expected_action(action, expected_action),
             :ok <- validate_expected_hostname(hostname, expected_hostnames) do
          {:ok, %{score: score, action: action, hostname: hostname}}
        else
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{"success" => false, "error-codes" => error_codes}} ->
        Logger.error("reCAPTCHA verification failed with errors: #{inspect(error_codes)}")
        {:error, :recaptcha_verification_failed}

      {:ok, response} ->
        Logger.error("Unexpected reCAPTCHA response format: #{inspect(response)}")
        {:error, :recaptcha_invalid_response}

      {:error, reason} ->
        Logger.error("Failed to parse reCAPTCHA response: #{inspect(reason)}")
        {:error, :recaptcha_parse_error}
    end
  end

  defp secret_key do
    System.get_env("RECAPTCHA_SECRET_KEY")
  end

  @spec maybe_put_remote_ip(map(), binary()) :: map()
  def maybe_put_remote_ip(params, remote_ip) when is_binary(remote_ip) do
    trimmed = String.trim(remote_ip)

    cond do
      trimmed == "" ->
        params

      trimmed == "unknown" ->
        # Don't send "unknown" to Google API
        params

      valid_ip?(trimmed) ->
        Map.put(params, "remoteip", trimmed)

      true ->
        # Invalid IP format - don't send it
        params
    end
  end

  @spec maybe_put_remote_ip(map(), any()) :: map()
  def maybe_put_remote_ip(params, _), do: params

  # Validates that a string is a valid IPv4 or IPv6 address.
  # Rejects IPv6 addresses with scope IDs (e.g., "fe80::1%eth0") as they
  # should not be sent to external APIs and are link-local only.
  defp valid_ip?(ip_string) when is_binary(ip_string) do
    trimmed = String.trim(ip_string)

    # Reject IPv6 with scope IDs (contains %)
    if String.contains?(trimmed, "%") do
      false
    else
      case :inet.parse_address(String.to_charlist(trimmed)) do
        {:ok, _} -> true
        {:error, _} -> false
      end
    end
  rescue
    e in ArgumentError ->
      # Handle string encoding errors (rare but possible with malformed input)
      Logger.debug("Failed to validate IP address",
        ip: inspect(ip_string),
        error: inspect(e)
      )
      false
  end

  @spec validate_min_score(number(), number()) :: :ok | {:error, atom()}
  def validate_min_score(score, min_score) when is_number(score) and is_number(min_score) do
    if score >= min_score do
      :ok
    else
      Logger.warning("reCAPTCHA score too low: #{score} (minimum: #{min_score})")
      {:error, :recaptcha_score_too_low}
    end
  end

  @spec validate_min_score(any(), number()) :: {:error, atom()}
  # Reject when the response score is non-numeric but min_score is correctly configured
  def validate_min_score(_score, min_score) when is_number(min_score) do
    Logger.warning("reCAPTCHA returned invalid (non-numeric) score")
    {:error, :recaptcha_invalid_score}
  end

  @spec validate_min_score(any(), any()) :: {:error, atom()} | :ok
  # Reject when min_score is not a number and not nil (configuration error)
  # This catches bugs like signup_min_score: "0.5" instead of 0.5
  def validate_min_score(_score, min_score) when not is_number(min_score) and min_score != nil do
    Logger.error("reCAPTCHA min_score configuration is invalid (not a number): #{inspect(min_score)}")
    {:error, :recaptcha_configuration_error}
  end

  @spec validate_min_score(any(), any()) :: :ok
  # Fallback: if min_score is nil or other edge cases, allow (optional validation)
  def validate_min_score(_score, _min_score), do: :ok

  @spec validate_expected_action(any(), nil) :: :ok
  def validate_expected_action(_action, nil), do: :ok

  @spec validate_expected_action(any(), binary()) :: :ok | {:error, atom()}
  def validate_expected_action(action, expected_action) when is_binary(expected_action) do
    if action == expected_action do
      :ok
    else
      Logger.warning("reCAPTCHA action mismatch",
        expected_action: expected_action,
        action: action
      )

      {:error, :recaptcha_action_mismatch}
    end
  end

  # NEW: Log when action field is missing but was expected
  def validate_expected_action(nil, expected_action) when is_binary(expected_action) do
    Logger.warning("reCAPTCHA response missing action field",
      expected_action: expected_action,
      hint: "Google may have omitted this field; verify your reCAPTCHA configuration"
    )

    {:error, :recaptcha_missing_action}
  end

  @spec validate_expected_hostname(any(), list()) :: :ok | {:error, atom()}
  def validate_expected_hostname(_hostname, []), do: :ok

  @spec validate_expected_hostname(any(), list()) :: :ok | {:error, atom()}
  def validate_expected_hostname(hostname, expected_hostnames)
       when is_list(expected_hostnames) do
    if hostname in expected_hostnames do
      :ok
    else
      Logger.warning("reCAPTCHA hostname mismatch",
        expected_hostnames: expected_hostnames,
        hostname: hostname
      )

      {:error, :recaptcha_hostname_mismatch}
    end
  end

  @spec validate_expected_hostname(nil, list()) :: {:error, atom()}
  # NEW: Log when hostname field is missing but was expected
  def validate_expected_hostname(nil, expected_hostnames)
       when is_list(expected_hostnames) and length(expected_hostnames) > 0 do
    Logger.warning("reCAPTCHA response missing hostname field",
      expected_hostnames: expected_hostnames,
      hint: "Google may have omitted this field; verify your reCAPTCHA configuration"
    )

    {:error, :recaptcha_missing_hostname}
  end
end
