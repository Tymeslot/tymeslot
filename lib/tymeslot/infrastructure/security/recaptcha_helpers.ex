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

  Seeded from `RECAPTCHA_SIGNUP_ENABLED` at boot and overridable at runtime
  via the admin settings UI (`Tymeslot.AppSettings`). Useful for emergency
  disables during outages without a redeploy.

  This is a *feature flag*; if enabled but keys are missing, signup verification is
  automatically disabled (and logged) so legitimate signups aren't blocked by misconfiguration.
  """
  @spec signup_enabled?() :: boolean()
  def signup_enabled? do
    :tymeslot
    |> Application.get_env(:recaptcha, [])
    |> Keyword.get(:signup_enabled, false)
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
  Whether booking reCAPTCHA checks are enabled.

  Seeded from `RECAPTCHA_BOOKING_ENABLED` at boot and overridable at runtime
  via the admin settings UI (`Tymeslot.AppSettings`). Useful for emergency
  disables during outages without a redeploy.

  This is a *feature flag*; if enabled but keys are missing, booking verification is
  automatically disabled (and logged) so legitimate bookings aren't blocked by misconfiguration.
  """
  @spec booking_enabled?() :: boolean()
  def booking_enabled? do
    :tymeslot
    |> Application.get_env(:recaptcha, [])
    |> Keyword.get(:booking_enabled, false)
  end

  # Default minimum score for booking reCAPTCHA verification.
  # Google recommends 0.5 for most cases, but we use 0.3 to reduce false positives
  # for legitimate users on VPNs, mobile networks, or with privacy extensions.
  # Combined with honeypot and rate limiting for defense in depth.
  @default_booking_min_score 0.3

  @doc """
  Returns the minimum reCAPTCHA score required for booking submissions.

  Defaults to #{@default_booking_min_score} if not configured. Lower scores are more
  permissive (reduce false positives) but may allow more bot traffic.
  """
  @spec booking_min_score() :: float()
  def booking_min_score do
    recaptcha_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Keyword.get(recaptcha_cfg, :booking_min_score, @default_booking_min_score)
  end

  @spec booking_action() :: String.t()
  def booking_action do
    recaptcha_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Keyword.get(recaptcha_cfg, :booking_action, "booking_form")
  end

  @spec booking_active?() :: boolean()
  def booking_active? do
    booking_enabled?() and key_present?(site_key()) and key_present?(secret_key())
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
  def validate_token(_token), do: {:error, :invalid_token}

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

      not active ->
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
      hint:
        "Check: JavaScript disabled, browser extension, or Content-Security-Policy blocking reCAPTCHA"
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
  Verify booking token if booking protection is enabled and configured.

  Accepts nil or empty tokens and handles them appropriately based on whether
  reCAPTCHA is enabled.

  ## Parameters

    * `token` - reCAPTCHA token from client (may be nil, empty, or a valid token)
    * `metadata` - Map containing `:ip` and `:user_agent` for logging (optional)

  ## Returns

  - `:ok` when checks are disabled or when verification passes
  - `{:error, :recaptcha_failed}` when enabled+configured but verification fails
  - `{:error, :recaptcha_script_blocked}` when reCAPTCHA script failed to load (JS disabled, CSP blocked, extension blocked)
  """
  @spec maybe_verify_booking_token(String.t() | nil, map()) ::
          :ok | {:error, :recaptcha_failed} | {:error, :recaptcha_script_blocked}
  def maybe_verify_booking_token(token, metadata \\ %{})

  def maybe_verify_booking_token(token, metadata) do
    # Check if booking reCAPTCHA is enabled and active
    enabled = booking_enabled?()
    active = booking_active?()

    cond do
      not enabled ->
        # Checks disabled; allow booking
        :ok

      not active ->
        # Enabled but keys missing; log and allow booking
        log_booking_disabled_due_to_missing_keys(metadata)
        :ok

      true ->
        # Enabled and active; verify the token
        verify_booking_token_impl(token, metadata)
    end
  end

  # Special marker: reCAPTCHA script failed to load (CSP, extension, JS disabled)
  defp verify_booking_token_impl("RECAPTCHA_SCRIPT_BLOCKED", metadata) do
    Logger.warning("Booking attempted with reCAPTCHA script blocked",
      event: "booking_recaptcha_script_blocked",
      ip: metadata[:ip],
      user_agent: metadata[:user_agent],
      hint:
        "Check: JavaScript disabled, browser extension, or Content-Security-Policy blocking reCAPTCHA"
    )

    {:error, :recaptcha_script_blocked}
  end

  defp verify_booking_token_impl(token, metadata) do
    # Provide defaults for logging metadata
    ip = metadata[:ip] || "unknown"
    user_agent = metadata[:user_agent] || "unknown"

    case Recaptcha.verify(token,
           min_score: booking_min_score(),
           expected_action: booking_action(),
           expected_hostnames: expected_hostnames(),
           remote_ip: ip
         ) do
      {:ok, %{score: score, action: action, hostname: hostname}} ->
        Logger.info("Booking reCAPTCHA passed",
          event: "booking_recaptcha_passed",
          score: score,
          threshold: booking_min_score(),
          action: action,
          hostname: hostname,
          ip: ip,
          user_agent: user_agent
        )

        :ok

      {:error, reason} ->
        Logger.warning("Booking reCAPTCHA failed",
          event: "booking_recaptcha_failed",
          reason: reason,
          threshold: booking_min_score(),
          ip: ip,
          user_agent: user_agent
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
  defp key_present?(_value), do: false

  # Avoid log spam by emitting at most once per minute per node.
  defp log_signup_disabled_due_to_missing_keys(metadata) do
    now_ms = System.system_time(:millisecond)
    key = {__MODULE__, :signup_disabled_missing_keys_last_logged_at}
    last_ms = :persistent_term.get(key, 0)

    if now_ms - last_ms >= 60_000 do
      :persistent_term.put(key, now_ms)

      Logger.warning(
        "Signup reCAPTCHA is enabled but missing keys; signup protection is disabled",
        event: "signup_recaptcha_disabled_missing_keys",
        ip: metadata[:ip],
        user_agent: metadata[:user_agent]
      )
    end
  end

  # Avoid log spam by emitting at most once per minute per node.
  # Uses atomics for thread-safe throttling without race conditions.
  defp log_booking_disabled_due_to_missing_keys(metadata) do
    now_sec = System.system_time(:second)
    key = {__MODULE__, :booking_disabled_missing_keys_throttle}

    # Create atomic counter on first use, or retrieve existing
    counter =
      case :persistent_term.get(key, nil) do
        nil ->
          ref = :atomics.new(1, [])
          :atomics.put(ref, 1, 0)
          :persistent_term.put(key, ref)
          ref

        existing ->
          existing
      end

    last_sec = :atomics.get(counter, 1)

    # Only log if 60 seconds have passed since last log
    if now_sec - last_sec >= 60 do
      # Atomically update timestamp only if it hasn't changed (prevents race)
      case :atomics.compare_exchange(counter, 1, last_sec, now_sec) do
        :ok ->
          # We won the race; emit the log
          Logger.warning(
            "Booking reCAPTCHA is enabled but missing keys; booking protection is disabled",
            event: "booking_recaptcha_disabled_missing_keys",
            ip: metadata[:ip] || "unknown",
            user_agent: metadata[:user_agent] || "unknown"
          )

        _race_condition ->
          # Another process won the race and already logged; skip
          :ok
      end
    end
  end
end
