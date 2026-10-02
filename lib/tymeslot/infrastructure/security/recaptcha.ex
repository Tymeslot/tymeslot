defmodule Tymeslot.Infrastructure.Security.Recaptcha do
  @moduledoc """
  reCAPTCHA v3 verification module for validating tokens.

  Only the token and the secret are sent to Google. The visitor's IP address is
  deliberately not forwarded as `remoteip`: Google documents it as optional and
  the score threshold does not depend on it.

  Every response that carries a score is logged once as
  `event: "recaptcha_verification"` with the score, action and outcome, so the
  score distribution and rejection rate can be compared over time.

  Google being unreachable is reported apart from Google's own verdict: a
  transport failure (refused connection, DNS failure, timeout) or a 5xx from
  siteverify returns `{:error, :recaptcha_service_unavailable}`, which says
  nothing about the visitor. Every other error is a verdict, or a response that
  could not be trusted, and means the token was not accepted. Callers decide
  what an outage means for them; most still reject.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @verify_url "https://www.google.com/recaptcha/api/siteverify"
  @default_minimum_score 0.3

  @type verify_opt ::
          {:min_score, float()}
          | {:expected_action, String.t() | nil}
          | {:expected_hostnames, [String.t()]}

  @doc """
  Verifies a reCAPTCHA token with Google's API.

  Returns `{:ok, %{score: float}}` on success or `{:error, reason}` on failure;
  `{:error, :recaptcha_service_unavailable}` means siteverify could not be
  reached or failed on Google's side (see the module documentation).
  """
  @spec verify(String.t(), [verify_opt()]) ::
          {:ok, %{score: float(), action: String.t() | nil, hostname: String.t() | nil}}
          | {:error, atom()}
  def verify(token, opts \\ [])

  def verify(token, opts) when is_binary(token) and byte_size(token) > 0 do
    # Reject tokens that exceed 5KB (real reCAPTCHA tokens are ~500 bytes)
    # This prevents DoS attacks with huge token payloads
    if byte_size(token) > 5_000 do
      Logger.warning("reCAPTCHA token exceeds size limit", token_size: byte_size(token))
      {:error, :invalid_token}
    else
      case secret_key() do
        key when is_binary(key) and byte_size(key) > 0 ->
          verify_with_secret(token, key, opts)

        _invalid ->
          Logger.error("reCAPTCHA verification failed: missing or invalid secret key")
          {:error, :recaptcha_configuration_error}
      end
    end
  end

  # A missing token is reported apart from a malformed one: a rise in missing
  # tokens points at the client never fetching one (script never loaded, form
  # posted before the token arrived), not at a bot.
  @spec verify(any(), any()) :: {:error, :missing_token | :invalid_token}
  def verify(token, _opts) when token in [nil, ""], do: {:error, :missing_token}
  def verify(_invalid_token, _opts), do: {:error, :invalid_token}

  defp verify_with_secret(token, secret_key, opts) do
    min_score = Keyword.get(opts, :min_score, @default_minimum_score)
    expected_action = Keyword.get(opts, :expected_action, nil)
    expected_hostnames = Keyword.get(opts, :expected_hostnames, [])

    body = URI.encode_query(%{"secret" => secret_key, "response" => token})

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case Config.http_client_module().post(@verify_url, body, headers,
           receive_timeout: 5000,
           connect_options: [timeout: 5000]
         ) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        handle_verification_response(
          response_body,
          min_score,
          expected_action,
          expected_hostnames
        )

      {:ok, %Req.Response{status: status_code}} when status_code in 500..599 ->
        Logger.error("reCAPTCHA siteverify unavailable", status_code: status_code)
        {:error, :recaptcha_service_unavailable}

      {:ok, %Req.Response{status: status_code}} ->
        Logger.error("reCAPTCHA verification failed with unexpected status",
          status_code: status_code
        )

        {:error, :recaptcha_request_failed}

      {:error, exception} ->
        Logger.error("reCAPTCHA siteverify unreachable", error: LogFormat.reason(exception))
        {:error, :recaptcha_service_unavailable}
    end
  end

  defp handle_verification_response(response_body, min_score, expected_action, expected_hostnames) do
    case Jason.decode(response_body) do
      {:ok, %{"success" => true, "score" => score} = decoded} when is_number(score) ->
        action = Map.get(decoded, "action")
        hostname = Map.get(decoded, "hostname")

        result =
          with :ok <- validate_min_score(score, min_score),
               :ok <- validate_expected_action(action, expected_action),
               :ok <- validate_expected_hostname(hostname, expected_hostnames) do
            {:ok, %{score: score, action: action, hostname: hostname}}
          end

        log_scored_verification(result, score, min_score, action)
        result

      {:ok, %{"success" => false, "error-codes" => error_codes}} ->
        Logger.error("reCAPTCHA verification failed with errors",
          error_codes: LogFormat.reason(error_codes)
        )

        {:error, :recaptcha_verification_failed}

      {:ok, response} ->
        Logger.error("Unexpected reCAPTCHA response format", response: LogFormat.reason(response))
        {:error, :recaptcha_invalid_response}

      {:error, reason} ->
        Logger.error("Failed to parse reCAPTCHA response", reason: LogFormat.reason(reason))
        {:error, :recaptcha_parse_error}
    end
  end

  defp secret_key do
    System.get_env("RECAPTCHA_SECRET_KEY")
  end

  defp log_scored_verification(result, score, min_score, action) do
    Logger.info("reCAPTCHA verification scored",
      event: "recaptcha_verification",
      outcome: verification_outcome(result),
      score: score,
      threshold: min_score,
      action: action
    )
  end

  defp verification_outcome({:ok, _details}), do: :passed
  defp verification_outcome({:error, reason}), do: reason

  @spec validate_min_score(number(), number()) :: :ok | {:error, atom()}
  def validate_min_score(score, min_score) when is_number(score) and is_number(min_score) do
    if score >= min_score do
      :ok
    else
      Logger.warning("reCAPTCHA score too low", score: score, minimum: min_score)
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
    Logger.error("reCAPTCHA min_score configuration is invalid (not a number)",
      min_score: LogFormat.reason(min_score)
    )

    {:error, :recaptcha_configuration_error}
  end

  @spec validate_min_score(any(), any()) :: :ok
  # Fallback: if min_score is nil or other edge cases, allow (optional validation)
  def validate_min_score(_score, _min_score), do: :ok

  @spec validate_expected_action(any(), nil) :: :ok
  def validate_expected_action(_action, nil), do: :ok

  @spec validate_expected_action(any(), binary()) :: :ok | {:error, atom()}
  # Log when the action field is missing but one was expected. Must precede the
  # general binary clause below — its unbound first arg would otherwise swallow nil.
  def validate_expected_action(nil, expected_action) when is_binary(expected_action) do
    Logger.warning("reCAPTCHA response missing action field",
      expected_action: expected_action,
      hint: "Google may have omitted this field; verify your reCAPTCHA configuration"
    )

    {:error, :recaptcha_missing_action}
  end

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

  @spec validate_expected_hostname(any(), list()) :: :ok | {:error, atom()}
  def validate_expected_hostname(_hostname, []), do: :ok

  @spec validate_expected_hostname(nil, list()) :: {:error, atom()}
  # Log when the hostname field is missing but one was expected. Must precede the
  # general list clause below — its unbound first arg would otherwise swallow nil.
  def validate_expected_hostname(nil, [_head | _tail] = expected_hostnames) do
    Logger.warning("reCAPTCHA response missing hostname field",
      expected_hostnames: expected_hostnames,
      hint: "Google may have omitted this field; verify your reCAPTCHA configuration"
    )

    {:error, :recaptcha_missing_hostname}
  end

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
end
