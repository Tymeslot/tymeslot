defmodule Tymeslot.Infrastructure.Security.RecaptchaHelpers do
  @moduledoc """
  Helper functions for reCAPTCHA v3 integration.
  """

  alias Tymeslot.Infrastructure.Security.Recaptcha
  require Logger

  @doc """
  Returns the reCAPTCHA site key from environment variables.
  """
  @spec site_key() :: String.t() | nil
  def site_key do
    System.get_env("RECAPTCHA_SITE_KEY")
  end

  @spec secret_key() :: String.t() | nil
  def secret_key do
    System.get_env("RECAPTCHA_SECRET_KEY")
  end

  @doc """
  Whether signup reCAPTCHA checks are enabled.

  This reads the RECAPTCHA_SIGNUP_ENABLED environment variable directly, allowing
  runtime toggling without redeployment (useful for emergency disables during outages).

  This is a *feature flag*; if enabled but keys are missing, signup verification is
  automatically disabled (and logged) so legitimate signups aren't blocked by misconfiguration.
  """
  @spec signup_enabled?() :: boolean()
  def signup_enabled? do
    recaptcha_cfg = Application.get_env(:tymeslot, :recaptcha, [])

    case Keyword.fetch(recaptcha_cfg, :signup_enabled) do
      {:ok, value} when is_boolean(value) ->
        value

      _ ->
        System.get_env("RECAPTCHA_SIGNUP_ENABLED", "false") == "true"
    end
  end

  @spec signup_min_score() :: float()
  def signup_min_score do
    recaptcha_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Keyword.get(recaptcha_cfg, :signup_min_score, 0.3)
  end

  @spec signup_action() :: String.t()
  def signup_action do
    recaptcha_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Keyword.get(recaptcha_cfg, :signup_action, "signup_form")
  end

  @spec expected_hostnames() :: [String.t()]
  def expected_hostnames do
    recaptcha_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Keyword.get(recaptcha_cfg, :expected_hostnames, [])
  end

  @spec signup_active?() :: boolean()
  def signup_active? do
    signup_enabled?() and key_present?(site_key()) and key_present?(secret_key())
  end

  @doc """
  Validates a reCAPTCHA token using the verification service.
  """
  @spec validate_token(String.t()) ::
          {:ok, %{score: float(), action: String.t() | nil, hostname: String.t() | nil}}
          | {:error, atom() | String.t()}
  def validate_token(token) when is_binary(token) and byte_size(token) > 0 do
    Recaptcha.verify(token)
  end

  @spec validate_token(any()) :: {:error, :invalid_token}
  def validate_token(_), do: {:error, :invalid_token}

  @doc """
  Verify signup token if signup protection is enabled and configured.

  Returns:
  - `:ok` when checks are disabled or when verification passes
  - `{:error, :recaptcha_failed}` when enabled+configured but verification fails
  - `{:error, :recaptcha_script_blocked}` when reCAPTCHA script failed to load (JS disabled, CSP blocked, extension blocked)
  """
  @spec maybe_verify_signup_token(String.t(), map()) ::
          :ok | {:error, :recaptcha_failed} | {:error, :recaptcha_script_blocked}
  def maybe_verify_signup_token(token, metadata \\ %{})

  def maybe_verify_signup_token(token, metadata) do
    # Check if signup reCAPTCHA is enabled and active
    enabled = signup_enabled?()
    active = signup_active?()

    cond do
      not enabled ->
        # Checks disabled; allow signup
        :ok

      enabled and not active ->
        # Enabled but keys missing; log and allow signup
        log_signup_disabled_due_to_missing_keys(metadata)
        :ok

      true ->
        # Enabled and active; verify the token
        verify_signup_token_impl(token, metadata)
    end
  end

  # Special marker: reCAPTCHA script failed to load (CSP, extension, JS disabled)
  defp verify_signup_token_impl("RECAPTCHA_SCRIPT_BLOCKED", metadata) do
    Logger.warning("Signup attempted with reCAPTCHA script blocked",
      event: "signup_recaptcha_script_blocked",
      ip: metadata[:ip],
      user_agent: metadata[:user_agent],
      hint: "Check: JavaScript disabled, browser extension, or Content-Security-Policy blocking reCAPTCHA"
    )

    {:error, :recaptcha_script_blocked}
  end

  defp verify_signup_token_impl(token, metadata) do
    case Recaptcha.verify(token,
           min_score: signup_min_score(),
           expected_action: signup_action(),
           expected_hostnames: expected_hostnames(),
           remote_ip: metadata[:ip]
         ) do
      {:ok, %{score: score, action: action, hostname: hostname}} ->
        Logger.info("Signup reCAPTCHA passed",
          event: "signup_recaptcha_passed",
          score: score,
          threshold: signup_min_score(),
          action: action,
          hostname: hostname,
          ip: metadata[:ip],
          user_agent: metadata[:user_agent]
        )

        :ok

      {:error, reason} ->
        Logger.warning("Signup reCAPTCHA failed",
          event: "signup_recaptcha_failed",
          reason: reason,
          threshold: signup_min_score(),
          ip: metadata[:ip],
          user_agent: metadata[:user_agent]
        )

        {:error, :recaptcha_failed}
    end
  end

  @doc """
  Generates a hidden input field for the reCAPTCHA token.
  """
  @spec recaptcha_hidden_input() :: String.t()
  def recaptcha_hidden_input do
    ~s(<input type="hidden" name="contact[g-recaptcha-response]" id="g-recaptcha-response" value="" />)
  end

  defp key_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp key_present?(_), do: false

  # Avoid log spam by emitting at most once per minute per node.
  defp log_signup_disabled_due_to_missing_keys(metadata) do
    now_ms = System.system_time(:millisecond)
    key = {__MODULE__, :signup_disabled_missing_keys_last_logged_at}
    last_ms = :persistent_term.get(key, 0)

    if now_ms - last_ms >= 60_000 do
      :persistent_term.put(key, now_ms)

      Logger.warning("Signup reCAPTCHA is enabled but missing keys; signup protection is disabled",
        event: "signup_recaptcha_disabled_missing_keys",
        ip: metadata[:ip],
        user_agent: metadata[:user_agent]
      )
    end
  end
end
