defmodule TymeslotWeb.Live.Scheduling.Handlers.BookingGuards do
  @moduledoc """
  The abuse gates a public booking submission must clear before it reaches the
  booking domain.

  Booking is unauthenticated and creates records, sends mail and can take
  payment, so it is the most attractive endpoint in the product to abuse. Four
  independent defences guard it, each covering a gap the others leave:

    * **Honeypot** — a hidden `website` field no human fills in. Checked before
      anything else because it is free, and answered with a *fake success* so a
      bot cannot tell a tripped honeypot from a real booking and adapt.
    * **Duplicate lock** — a per-session flag stopping a double-clicked form
      from creating two meetings.
    * **Per-IP rate limit** — the general flood defence.
    * **reCAPTCHA** — scripted submissions that pace themselves under the IP
      limit.
    * **Per-recipient rate limit** — keyed on the attendee's email, this is the
      one that survives an attacker rotating source IPs to bomb a single
      mailbox with confirmation mail. It runs on the *validated* address, so it
      must come after form validation.

  ## Why they are composed here

  `run/3` applies them in one place and in a fixed order. Spread across a
  caller's `with` chain, a new submission path is one forgotten clause away
  from being unprotected, and the ordering constraints above are invisible.

  Every failure exits through `release_submission/1`. The duplicate lock is
  claimed before the later gates run, so a branch that clears only
  `:submitting` leaves `:submission_processed` set and wedges the form: every
  retry in that session is refused as "already being processed" until the
  booker reloads the page.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Shared.Flash

  require Logger

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:ok, socket()} | {:error, socket()}

  @doc """
  Runs every gate that applies once the form itself has validated.

  `sanitized_params` supplies the validated attendee address for the
  per-recipient limit; `raw_params` carries the reCAPTCHA token, which is not
  part of the booking form spec and so does not survive sanitisation.
  """
  @spec run(socket(), map(), map()) :: result()
  def run(socket, sanitized_params, raw_params) do
    with {:ok, socket} <- check_duplicate_submission(socket),
         {:ok, socket} <- check_rate_limit(socket),
         :ok <- verify_recaptcha(socket, raw_params) do
      check_recipient_rate_limit(socket, sanitized_params)
    end
  end

  @doc """
  Whether the hidden honeypot field was filled in.

  Checked before form validation: it is the cheapest gate and a tripped
  honeypot means nothing else about the submission is worth processing.
  """
  @spec honeypot_tripped?(map()) :: boolean()
  def honeypot_tripped?(params) do
    case Map.get(params, "website") do
      value when is_binary(value) -> value != ""
      _other -> false
    end
  end

  @doc """
  Logs the honeypot hit and returns the socket for a simulated success.

  The caller reports success to the bot. Telling it the truth would let it
  discover the field and skip it next time.
  """
  @spec handle_honeypot(socket()) :: socket()
  def handle_honeypot(socket) do
    SecurityLogger.log_security_event("booking_honeypot_triggered", %{
      ip_address: ClientIP.get(socket),
      user_agent: ClientIP.get_user_agent(socket)
    })

    Logger.info("Honeypot triggered in booking form - simulating success")

    socket
    |> assign(:submitting, false)
    |> assign(:custom_fields_snapshot, [])
    |> assign(:custom_field_answers, %{})
  end

  @doc """
  Ends an in-flight submission attempt.

  Clears the spinner *and* releases the duplicate-submission lock. Both flags
  must move together; route every non-success exit through here rather than
  assigning them by hand.
  """
  @spec release_submission(socket()) :: socket()
  def release_submission(socket) do
    socket
    |> assign(:submitting, false)
    |> assign(:submission_processed, false)
  end

  defp check_duplicate_submission(socket) do
    if socket.assigns[:submission_processed] do
      Logger.warning("Duplicate submission attempt detected")

      socket =
        Flash.put_flash(
          socket,
          :warning,
          dgettext("booking", "Your booking is already being processed. Please wait...")
        )

      {:error, socket}
    else
      socket =
        socket
        |> assign(:submission_processed, true)
        |> assign(:submitting, true)

      {:ok, socket}
    end
  end

  defp check_rate_limit(socket) do
    client_ip = ClientIP.get(socket)

    case RateLimiter.check_booking_submission_limit(client_ip) do
      {:allow, _count} ->
        {:ok, socket}

      {:deny, _limit} ->
        Logger.warning("Booking rate limit exceeded", client_ip: inspect(client_ip))
        {:error, too_many_attempts(socket)}
    end
  end

  defp check_recipient_rate_limit(socket, %{"email" => email})
       when is_binary(email) and email != "" do
    case RateLimiter.check_booking_recipient_limit(email) do
      :ok ->
        {:ok, socket}

      {:error, :rate_limited, _message} ->
        Logger.warning("Booking recipient rate limit exceeded",
          operation: "booking",
          limit_type: "recipient"
        )

        {:error, too_many_attempts(socket)}
    end
  end

  defp check_recipient_rate_limit(socket, _params), do: {:ok, socket}

  # Deliberately the same wording for the per-IP and per-recipient limits: a
  # distinguishable message would tell an attacker which limit they hit and so
  # which axis to vary.
  defp too_many_attempts(socket) do
    socket
    |> release_submission()
    |> Flash.put_flash(
      :error,
      dgettext("booking", "Too many booking attempts. Please try again later.")
    )
  end

  defp verify_recaptcha(socket, raw_params) do
    metadata = %{
      ip: ClientIP.get(socket),
      user_agent: ClientIP.get_user_agent(socket)
    }

    raw_params
    |> Map.get("g-recaptcha-response", "")
    |> RecaptchaHelpers.maybe_verify_booking_token(metadata)
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, recaptcha_error(socket, reason)}
    end
  end

  defp recaptcha_error(socket, :recaptcha_failed) do
    socket
    |> release_submission()
    |> Flash.put_flash(
      :error,
      dgettext("booking", "Security verification failed. Please try again.")
    )
  end

  defp recaptcha_error(socket, :recaptcha_script_blocked) do
    socket
    |> release_submission()
    |> Flash.put_flash(
      :error,
      dgettext(
        "booking",
        "Security verification is currently unavailable. This may be caused by JavaScript being disabled, browser privacy extensions (Privacy Badger, uBlock Origin, etc.), or network security policies. Please adjust your settings or contact support if the problem persists."
      )
    )
  end
end
