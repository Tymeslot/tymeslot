defmodule Tymeslot.Auth.SignupSecurity do
  @moduledoc """
  Layered security gate for new-account signup.

  Runs the hybrid pipeline that decides whether a signup submission may
  proceed to actual user creation:

  1. **Honeypot** — a hidden form field that legitimate browsers leave empty;
     bots that auto-fill all fields trip it.
  2. **Rate limit** — fast per-email + per-IP gate that runs before
     reCAPTCHA so distributed bots cannot burn Google API quota.
  3. **reCAPTCHA v3** — score-based human verification.

  This module owns the gate decision only. The caller (typically the auth
  LiveView) is responsible for the subsequent state transitions, flash
  messages, and the actual `Tymeslot.Auth.AuthActions.register_user/2`
  call once the gate returns `:ok`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.SecurityLogger

  @type metadata :: %{
          required(:ip) => String.t() | nil,
          optional(:user_agent) => String.t() | nil
        }

  @type gate_result ::
          :ok
          | :honeypot
          | {:error, :rate_limited, String.t()}
          | {:error, :recaptcha_failed, String.t()}
          | {:error, :recaptcha_script_blocked, String.t()}

  @doc """
  Decides whether a signup submission should proceed to registration.

  Returns:
  - `:honeypot` — bot-filled honeypot, caller should fake success
  - `:ok` — human submission within rate limits, caller may register
  - `{:error, kind, message}` — rejected by rate limiter or reCAPTCHA
  """
  @spec gate(map(), metadata()) :: gate_result()
  def gate(user_params, metadata) do
    if honeypot_tripped?(user_params) do
      log_honeypot_signup(metadata)
      :honeypot
    else
      with :ok <- check_rate_limit(user_params, metadata) do
        verify_recaptcha(user_params, metadata)
      end
    end
  end

  @doc """
  Logs a honeypot-triggered "resend verification" attempt — the bot has
  followed the decoy success path and is requesting another email.
  """
  @spec log_honeypot_resend(metadata()) :: :ok
  def log_honeypot_resend(metadata) do
    SecurityLogger.log_security_event("signup_honeypot_resend", %{
      ip_address: metadata[:ip],
      user_agent: metadata[:user_agent]
    })
  end

  defp honeypot_tripped?(params) do
    case Map.get(params, "website") do
      value when is_binary(value) -> value != ""
      _other -> false
    end
  end

  defp log_honeypot_signup(metadata) do
    SecurityLogger.log_security_event("signup_honeypot_triggered", %{
      ip_address: metadata[:ip],
      user_agent: metadata[:user_agent]
    })
  end

  defp check_rate_limit(user_params, metadata) do
    email = user_params["email"]

    if is_binary(email) and email != "" do
      case RateLimiter.check_signup_rate_limit(email, metadata[:ip]) do
        :ok ->
          :ok

        {:error, :rate_limited, reason} ->
          AccountLogging.log_rate_limit_exceeded("signup", email, %{ip_address: metadata[:ip]})
          {:error, :rate_limited, reason}
      end
    else
      {:error, :rate_limited,
       dgettext("auth", "Too many signup attempts. Please try again later.")}
    end
  end

  defp verify_recaptcha(user_params, metadata) do
    token = Map.get(user_params, "g-recaptcha-response", "")

    case RecaptchaHelpers.maybe_verify_signup_token(token, metadata) do
      :ok ->
        :ok

      {:error, :recaptcha_failed} ->
        {:error, :recaptcha_failed,
         dgettext("auth", "Security verification failed. Please try again.")}

      {:error, :recaptcha_script_blocked} ->
        {:error, :recaptcha_script_blocked,
         dgettext(
           "auth",
           "Security verification unavailable. Please enable JavaScript and refresh the page, or contact support if the problem persists."
         )}
    end
  end
end
