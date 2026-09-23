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

  ## Only a session-bound account is ever sent anything

  The resend goes to the unverified user bound to this session (proved by
  password at login, or created by this process at sign-up), never to an
  address typed into a form. Every outcome, sent, unknown, already verified or
  over the account's own allowance, reads "Verification email sent!", so the
  button cannot be used to learn whether an address has an account.

  ## With nothing bound, the answer depends only on the session

  A reload or a direct visit binds no account and follows no sign-up. The
  resend then sends the visitor to sign in, which binds their account again
  once the password is proved. A sign-up answered in this process (see below)
  keeps the "sent" reply instead, since it has to match a genuine one.

  ## Honeypot and duplicate signups have nothing to resend

  A signup caught by the honeypot, or one for an address that already had an
  account, bound no user, so there is no email to send. It still has to *look*
  identical, down to the rate limiting, or the difference in behaviour is
  itself the tell.
  """

  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Tymeslot.Auth.{SignupSecurity, Verification}
  alias Tymeslot.Security.SecurityLogger
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
    if bound_email(socket) || socket.assigns[:signed_up_here] do
      do_resend(socket)
    else
      {:noreply, sign_in_first(socket)}
    end
  end

  # No account is bound and this process answered no sign-up: a reload, or a
  # direct visit. That is all the answer depends on, so it names no account
  # and claims no email; signing in with the password binds the account again.
  defp sign_in_first(socket) do
    socket
    |> put_flash(:info, dgettext("auth", "Sign in to receive a new verification link."))
    |> push_patch(to: ~p"/auth/login")
  end

  defp do_resend(socket) do
    socket = start_cooldown(socket)

    case attempt(socket) do
      :sent -> {:noreply, done(socket, :info, sent_message())}
      {:rate_limited, message} -> {:noreply, done(socket, :error, message)}
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

  # The only address a resend ever goes to is the session-bound unverified
  # user's: one that proved its password at login, or that this very process
  # just created at sign-up. Nothing typed into a form reaches here, and with
  # no bound user the domain still charges the address bucket and answers as
  # if an email went out, so the reply cannot tell anyone which case applied.
  defp attempt(socket) do
    case Verification.resend_verification_email_by_email(bound_email(socket), socket) do
      :ok ->
        maybe_log_honeypot(socket)
        :sent

      {:error, :rate_limited, message} ->
        maybe_log_honeypot_violation(socket)
        {:rate_limited, message}
    end
  end

  defp bound_email(%{assigns: %{unverified_user: %{email: email}}}) when is_binary(email),
    do: email

  defp bound_email(_socket), do: nil

  defp maybe_log_honeypot(%{assigns: %{honeypot_signup: true}} = socket) do
    socket |> SecurityHelper.extract_client_metadata() |> SignupSecurity.log_honeypot_resend()
  end

  defp maybe_log_honeypot(_socket), do: :ok

  # This is the resend rate limit rejecting traffic the honeypot has already
  # flagged as a bot, so it's the one worth recording separately. There is no
  # account to identify it by, so `identifier` is `nil`.
  defp maybe_log_honeypot_violation(%{assigns: %{honeypot_signup: true}} = socket) do
    metadata = SecurityHelper.extract_client_metadata(socket)

    SecurityLogger.log_rate_limit_violation(nil, "email_verification_honeypot", %{
      ip_address: SecurityHelper.rate_limit_ip(metadata),
      user_agent: metadata.user_agent
    })
  end

  defp maybe_log_honeypot_violation(_socket), do: :ok

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
