defmodule Tymeslot.Infrastructure.Security.RecaptchaHelpers do
  @moduledoc """
  Helper functions for reCAPTCHA v3 integration.
  """

  alias Tymeslot.Infrastructure.Security.Recaptcha
  require Logger

  # Sent by `assets/js/hooks/recaptcha_v3_hook.js` in place of a token when the
  # reCAPTCHA script could not load.
  @script_blocked_marker "RECAPTCHA_SCRIPT_BLOCKED"

  @doc """
  Returns the reCAPTCHA site key from environment variables.
  """
  @spec site_key() :: String.t() | nil
  def site_key do
    System.get_env("RECAPTCHA_SITE_KEY")
  end

  @spec secret_key() :: String.t() | nil
  defp secret_key do
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
  defp signup_action do
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
  Whether any reCAPTCHA check is active on this instance.

  The single answer to "does this instance use reCAPTCHA at all": the
  Content-Security-Policy allows Google's origins only while it is true, so a
  form that loads the reCAPTCHA script or demands a token must ask this same
  question, or the policy blocks the script the form is waiting on.
  """
  @spec any_active?() :: boolean()
  def any_active?, do: booking_active?() or signup_active?()

  @doc """
  Verify signup token if signup protection is enabled and configured.

  Returns:
  - `:ok` when checks are disabled, when verification passes, or when Google
    could not be reached (see `verify_failing_open/4`)
  - `{:error, :recaptcha_failed}` when enabled+configured but verification fails
  - `{:error, :recaptcha_script_blocked}` when the client reported the reCAPTCHA
    script could not load (JS disabled, CSP blocked, extension blocked) and
    Google, asked anyway, rejected the marker
  """
  @spec maybe_verify_signup_token(String.t(), map()) ::
          :ok | {:error, :recaptcha_failed} | {:error, :recaptcha_script_blocked}
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
        verify_form_token(:signup, token, metadata)
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

  - `:ok` when checks are disabled, when verification passes, or when Google
    could not be reached (see `verify_failing_open/4`)
  - `{:error, :recaptcha_failed}` when enabled+configured but verification fails
  - `{:error, :recaptcha_script_blocked}` when the client reported the reCAPTCHA
    script could not load (JS disabled, CSP blocked, extension blocked) and
    Google, asked anyway, rejected the marker
  """
  @spec maybe_verify_booking_token(String.t() | nil, map()) ::
          :ok | {:error, :recaptcha_failed} | {:error, :recaptcha_script_blocked}
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
        verify_form_token(:booking, token, metadata)
    end
  end

  @doc """
  Verifies a reCAPTCHA token, accepting the submission without a verdict if,
  and only if, Google could not be reached.

  The one outage policy for every public form. Losing a booking, a sign-up or a
  message to a Google outage costs more than letting a little spam through
  while it lasts, and the honeypot and rate limits still apply. Everything
  else still rejects: every verdict Google gives (a rejected token, a low
  score, a mismatched action or hostname), a missing or oversized token, and a
  missing secret.

  The script-blocked marker the client hook sends when the reCAPTCHA script
  cannot load is verified like any token, never answered locally: Google
  rejects it while siteverify answers, so it passes only when siteverify is
  unreachable too.

  `event` is the `event:` key of the warning logged when a submission is
  accepted without a verdict; `metadata` may carry `:ip` and `:user_agent` for
  it. `opts` are `Recaptcha.verify/2`'s.

  Returns `{:ok, details}` for a passing verdict, `{:ok, :service_unavailable}`
  for a submission accepted during an outage, and `{:error, reason}` otherwise.
  """
  @spec verify_failing_open(term(), String.t(), map(), [Recaptcha.verify_opt()]) ::
          {:ok, %{score: float(), action: String.t() | nil, hostname: String.t() | nil}}
          | {:ok, :service_unavailable}
          | {:error, atom()}
  def verify_failing_open(token, event, metadata, opts \\ []) do
    case Recaptcha.verify(token, opts) do
      {:error, :recaptcha_service_unavailable} ->
        Logger.warning("Submission accepted without reCAPTCHA: siteverify unavailable",
          event: event,
          script_blocked: token == @script_blocked_marker,
          ip: metadata[:ip] || "unknown",
          user_agent: metadata[:user_agent] || "unknown"
        )

        {:ok, :service_unavailable}

      result ->
        result
    end
  end

  # The booking and signup checks differ only in their settings and in the
  # names their log lines carry.
  @form_logs %{
    booking: %{
      passed: {"Booking reCAPTCHA passed", "booking_recaptcha_passed"},
      failed: {"Booking reCAPTCHA failed", "booking_recaptcha_failed"},
      script_blocked:
        {"Booking attempted with reCAPTCHA script blocked", "booking_recaptcha_script_blocked"},
      unavailable: "booking_recaptcha_unavailable"
    },
    signup: %{
      passed: {"Signup reCAPTCHA passed", "signup_recaptcha_passed"},
      failed: {"Signup reCAPTCHA failed", "signup_recaptcha_failed"},
      script_blocked:
        {"Signup attempted with reCAPTCHA script blocked", "signup_recaptcha_script_blocked"},
      unavailable: "signup_recaptcha_unavailable"
    }
  }

  defp verify_form_token(form, token, metadata) do
    logs = Map.fetch!(@form_logs, form)
    {passed_message, passed_event} = logs.passed
    {failed_message, failed_event} = logs.failed
    {blocked_message, blocked_event} = logs.script_blocked
    threshold = form_min_score(form)
    ip = metadata[:ip] || "unknown"
    user_agent = metadata[:user_agent] || "unknown"

    opts = [
      min_score: threshold,
      expected_action: form_action(form),
      expected_hostnames: expected_hostnames()
    ]

    case verify_failing_open(token, logs.unavailable, metadata, opts) do
      {:ok, :service_unavailable} ->
        :ok

      {:ok, %{score: score, action: action, hostname: hostname}} ->
        Logger.info(passed_message,
          event: passed_event,
          score: score,
          threshold: threshold,
          action: action,
          hostname: hostname,
          ip: ip,
          user_agent: user_agent
        )

        :ok

      # Google answered and refused the marker: the script really did not load
      # in a browser while reCAPTCHA was up, so the visitor gets the advice that
      # fits (enable JavaScript, allow the script) rather than a bare failure.
      {:error, _reason} when token == @script_blocked_marker ->
        Logger.warning(blocked_message,
          event: blocked_event,
          ip: ip,
          user_agent: user_agent,
          hint:
            "Check: JavaScript disabled, browser extension, or Content-Security-Policy blocking reCAPTCHA"
        )

        {:error, :recaptcha_script_blocked}

      {:error, reason} ->
        Logger.warning(failed_message,
          event: failed_event,
          reason: reason,
          threshold: threshold,
          ip: ip,
          user_agent: user_agent
        )

        {:error, :recaptcha_failed}
    end
  end

  defp form_min_score(:booking), do: booking_min_score()
  defp form_min_score(:signup), do: signup_min_score()

  defp form_action(:booking), do: booking_action()
  defp form_action(:signup), do: signup_action()

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
