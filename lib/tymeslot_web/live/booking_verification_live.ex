defmodule TymeslotWeb.BookingVerificationLive do
  @moduledoc """
  Where an attendee confirms a held booking from the link in their
  verification email, or disowns one they never made.

  Reachable without a session: the signed token
  (`Tymeslot.Meetings.EmailVerificationToken`) is the authorisation. The page
  shows no uid and offers no cancel or reschedule link, since the booking does
  not exist for anybody else until it is verified.

  ## Nothing happens on load

  Mail security products and link-preview crawlers fetch every URL in an
  inbound message, so loading the page only reads. Confirming and disowning
  are `phx-click`s, which arrive over the LiveView socket and no crawler
  sends. Each re-verifies the token, so it acts on the booking as stored now
  rather than on the copy read when the page connected, and both share one
  rate limit per client.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationToken
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.BookingVerificationLive.View
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Shared.RateLimit
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def render(assigns), do: View.page(assigns)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("booking_manage", "Confirm your booking"),
       state: :loading,
       meeting: nil,
       token: nil,
       rebook_path: nil,
       locale: nil
     )}
  end

  # The token read is a database read, so it waits for the connected render
  # rather than running on the static one a plain GET triggers. Until then
  # the page says only that it is checking the link (`:loading`), so neither
  # a scanner's GET nor the first paint calls a good link invalid.
  @impl Phoenix.LiveView
  def handle_params(%{"token" => token}, _uri, socket) do
    socket = assign(socket, :token, token)

    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("confirm", _params, socket), do: {:noreply, act(socket, &confirm/2)}
  def handle_event("release", _params, socket), do: {:noreply, act(socket, &release/2)}

  defp load(socket) do
    case EmailVerificationToken.verify(socket.assigns.token) do
      {:ok, meeting} ->
        show(socket, meeting, state_for(meeting))

      {:error, reason} ->
        Logger.info("Rejected booking verification link", reason: LogFormat.reason(reason))
        show(socket, nil, :invalid)
    end
  end

  defp show(socket, meeting, :expired) do
    socket
    |> put_attendee_locale(meeting)
    |> assign(meeting: meeting, state: :expired, rebook_path: rebook_path(meeting))
  end

  defp show(socket, meeting, state) do
    socket
    |> put_attendee_locale(meeting)
    |> assign(meeting: meeting, state: state, rebook_path: nil)
  end

  # The page speaks the language the booking was made in, as the email that
  # linked here does, rather than whatever the app surface would resolve:
  # the booking pages keep their language choice apart from it.
  defp put_attendee_locale(socket, nil), do: socket

  defp put_attendee_locale(socket, meeting) do
    locale = RecipientLocale.attendee_locale(meeting)
    Gettext.put_locale(locale)

    assign(socket,
      locale: locale,
      page_title: dgettext("booking_manage", "Confirm your booking")
    )
  end

  # A verified booking that was later cancelled has nothing true to show here:
  # it is neither confirmed nor expired, so it reads as a link out of date.
  # An unverified booking can only reach `:cancelled` through `release/1`,
  # the attendee disowning it.
  defp state_for(%{email_verified_at: %DateTime{}} = meeting) do
    if MeetingState.released_status?(meeting.status), do: :invalid, else: :already_verified
  end

  defp state_for(%{status: :cancelled}), do: :released
  defp state_for(%{status: :expired}), do: :expired

  defp state_for(meeting) do
    cond do
      not MeetingState.awaiting_verification?(meeting) -> :invalid
      deadline_passed?(meeting) -> :expired
      true -> :awaiting
    end
  end

  # The deadline itself counts as passed, as it does in the domain.
  defp deadline_passed?(%{verification_deadline_at: %DateTime{} = deadline}),
    do: DateTime.compare(Clock.utc_now(), deadline) != :lt

  defp deadline_passed?(_meeting), do: false

  defp act(socket, action) do
    RateLimit.with_rate_limit(
      RateLimiter.check(:booking_email_verification, ClientIP.get(socket)),
      socket,
      fn -> act_on_current(socket, action) end,
      message: dgettext("booking_manage", "Too many attempts. Try again in a moment."),
      flash: :socket,
      reply: :socket
    )
  end

  defp act_on_current(socket, action) do
    case EmailVerificationToken.verify(socket.assigns.token) do
      {:ok, meeting} -> action.(socket, meeting)
      {:error, _reason} -> show(socket, nil, :invalid)
    end
  end

  defp confirm(socket, meeting) do
    case EmailVerification.verify(meeting) do
      {:ok, :verified, verified} ->
        state =
          if MeetingState.awaiting_approval?(verified), do: :verified_request, else: :verified

        show(socket, verified, state)

      {:ok, :already_verified, current} ->
        show(socket, current, :already_verified)

      # Released, by the deadline or by an exit that won a race: the stored
      # row says which.
      {:error, :expired} ->
        load(socket)

      {:error, :not_scheduled} ->
        socket
        |> show(meeting, :failed)
        |> put_flash(
          :error,
          dgettext(
            "booking_manage",
            "We could not confirm your booking just now. Please try again."
          )
        )
    end
  end

  # Somebody got there first (a confirmation in another tab, the expiry
  # job): show what the booking actually became.
  defp release(socket, meeting) do
    case EmailVerification.release(meeting) do
      {:ok, released} -> show(socket, released, :released)
      {:error, :not_awaiting_verification} -> load(socket)
    end
  end

  # The token proves the visitor is the guest, so an invitation the booking
  # used is offered back with the link. Past its deadline but before the
  # expiry job has run, the booking still holds its invitation, which the
  # booking page would refuse as used, so the link leaves the token off.
  defp rebook_path(%{organizer_user_id: user_id} = meeting) when is_integer(user_id) do
    case Profiles.get_profile(user_id) do
      nil -> nil
      profile -> rebook_path(profile, meeting)
    end
  end

  defp rebook_path(_meeting), do: nil

  defp rebook_path(profile, meeting) do
    case PaymentReturn.rebook(profile, meeting, true) do
      %{invitation_held: true} -> PaymentReturn.booking_path(profile, meeting)
      %{rebook_path: path} -> path
    end
  end
end
