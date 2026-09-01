defmodule TymeslotWeb.AuthLive.VerificationEvents do
  @moduledoc """
  Resending the verification email, lifted out of `TymeslotWeb.AuthLive`.

  ## The cooldown starts on every click

  The countdown is started before anything else happens, and regardless of how
  the resend turns out. Only starting it on success would leave the button live
  while a rate-limited or errored request is in flight, which is exactly when it
  gets clicked again. Server-side rate limiting remains the real boundary; this
  is the UX guard in front of it.

  A click arriving while the countdown is still running is dropped rather than
  restarting it: the button is disabled client-side, but a fast double-click can
  deliver a second event before the DOM patch lands, and handling it would spawn
  a second timer chain that drains the countdown at twice the rate.

  ## Honeypot signups have nothing to resend

  A signup caught by the honeypot never created an account, so there is no email
  to send. It still has to *look* identical, down to the rate limiting, or the
  difference in behaviour is itself the tell.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tymeslot.Auth.{Session, SignupSecurity, Verification}
  alias Tymeslot.Security.{RateLimiter, SecurityLogger}
  alias TymeslotWeb.AuthLive.SecurityHelper

  @typedoc "A LiveView `handle_event/3` return value."
  @type reply :: {:noreply, Phoenix.LiveView.Socket.t()}

  # How long the button stays disabled after a click, with a live countdown.
  @cooldown_seconds 60
  @tick_ms 1000

  @doc """
  Resends the verification email, starting the cooldown either way.
  """
  @spec resend(Phoenix.LiveView.Socket.t()) :: reply()
  def resend(socket) do
    socket = start_cooldown(socket)

    case attempt(socket) do
      :sent -> {:noreply, done(socket, :info, sent_message())}
      {:rate_limited, message} -> {:noreply, done(socket, :error, message)}
      {:failed, message} -> {:noreply, done(socket, :error, message)}
    end
  end

  @doc """
  Advances the countdown by one second, rescheduling itself until it runs out.
  """
  @spec tick(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def tick(socket) do
    case socket.assigns.resend_cooldown - 1 do
      remaining when remaining > 0 ->
        schedule_tick()
        {:noreply, assign(socket, :resend_cooldown, remaining)}

      _elapsed ->
        {:noreply, assign(socket, :resend_cooldown, 0)}
    end
  end

  @doc """
  Whether a cooldown is currently running, and the click should be ignored.
  """
  @spec cooling_down?(Phoenix.LiveView.Socket.t()) :: boolean()
  def cooling_down?(%{assigns: %{resend_cooldown: remaining}}) when is_integer(remaining),
    do: remaining > 0

  def cooling_down?(_socket), do: false

  defp attempt(%{assigns: %{honeypot_signup: true}} = socket) do
    metadata = SecurityHelper.extract_client_metadata(socket)

    case RateLimiter.check_verification_rate_limit(
           "honeypot",
           SecurityHelper.rate_limit_ip(metadata)
         ) do
      :ok ->
        SignupSecurity.log_honeypot_resend(metadata)
        :sent

      {:error, :rate_limited, message} ->
        # This is the resend rate limit rejecting traffic the honeypot has
        # already flagged as a bot, so it's the one worth recording. There
        # is no account to identify it by: `identifier` is `nil` rather than
        # the "honeypot" bucket tag, which would be filed under `:email` and
        # dropped by masking as unparseable.
        SecurityLogger.log_rate_limit_violation(nil, "email_verification_honeypot", %{
          ip_address: SecurityHelper.rate_limit_ip(metadata),
          user_agent: metadata.user_agent
        })

        {:rate_limited, message}
    end
  end

  defp attempt(socket) do
    case Session.get_verification_email(socket) do
      nil ->
        {:failed,
         dgettext("auth", "Unable to resend verification email. Please try signing up again.")}

      email ->
        send_to(email, socket)
    end
  end

  defp send_to(email, socket) do
    case Verification.resend_verification_email_by_email(email, socket) do
      {:ok, _user} ->
        :sent

      {:error, :rate_limited, message} ->
        {:rate_limited, message}

      {:error, _reason} ->
        {:failed, dgettext("auth", "Failed to send verification email. Please try again later.")}
    end
  end

  defp start_cooldown(socket) do
    schedule_tick()
    assign(socket, :resend_cooldown, @cooldown_seconds)
  end

  defp schedule_tick, do: Process.send_after(self(), :resend_cooldown_tick, @tick_ms)

  defp done(socket, level, message) do
    socket |> assign(:loading, false) |> put_flash(level, message)
  end

  defp sent_message,
    do: dgettext("auth", "Verification email sent! Please check your inbox.")
end
