defmodule TymeslotWeb.BookingVerificationLive do
  @moduledoc """
  Where an attendee confirms a held booking from the link in their
  verification email, or disowns one they never made.

  Reachable without a session: the signed token
  (`Tymeslot.Meetings.EmailVerificationToken`) is the authorisation. The page
  shows no uid and offers no cancel or reschedule link, since the booking does
  not exist for anybody else until it is verified.

  A seat on a group meeting has its own token (`{:seat, seat, slot}` from the
  token), and the page reads its state from the seat and whether its slot
  still occupies its time, never from the slot's own deadline, which is only
  the first held seat's. A seat cannot await approval, since group types
  cannot require it.

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
  alias Tymeslot.Meetings.MeetingSchema
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
       seat: nil,
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
      {:ok, held} ->
        show(socket, held, state_for(held))

      {:error, reason} ->
        Logger.info("Rejected booking verification link", reason: LogFormat.reason(reason))
        show(socket, nil, :invalid)
    end
  end

  # `held` is what the token was issued for: a meeting, `{:seat, seat, slot}`,
  # or nil once the link reads as invalid.
  defp show(socket, held, state) do
    {meeting, seat} = split(held)
    rebook_path = if state == :expired, do: rebook_path(meeting)

    socket
    |> put_attendee_locale(seat || meeting)
    |> assign(meeting: meeting, seat: seat, state: state, rebook_path: rebook_path)
  end

  defp split({:seat, seat, slot}), do: {slot, seat}
  defp split(meeting), do: {meeting, nil}

  # A seat verified and later cancelled, or whose slot was, reads as a link
  # out of date, as a one-to-one booking does; one whose slot awaits a new
  # time still stands, confirmed, as a one-to-one booking awaiting one does.
  # A held seat released by its deadline or by its booker has no status to
  # tell the two apart, so both read as expired. A held seat on a slot
  # voided by a reschedule request is still held, so it reads as awaiting,
  # and confirming it is refused while the request is pending.
  defp state_for({:seat, %{email_verified_at: %DateTime{}} = seat, slot}) do
    if EmailVerification.seat_standing(slot, seat) == :gone,
      do: :invalid,
      else: :already_verified
  end

  defp state_for({:seat, seat, slot}) do
    if EmailVerification.seat_standing(slot, seat) == :gone, do: :expired, else: :awaiting
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

  # The page speaks the language the booking was made in, as the email that
  # linked here does, rather than whatever the app surface would resolve:
  # the booking pages keep their language choice apart from it. A seat
  # carries its own booker's language.
  defp put_attendee_locale(socket, nil), do: socket

  defp put_attendee_locale(socket, held) do
    locale = RecipientLocale.attendee_locale(locale_source(held))
    Gettext.put_locale(locale)

    assign(socket,
      locale: locale,
      page_title: dgettext("booking_manage", "Confirm your booking")
    )
  end

  defp locale_source(%MeetingSchema{} = meeting), do: meeting
  defp locale_source(seat), do: %{attendee_locale: seat.locale}

  defp deadline_passed?(held), do: EmailVerification.deadline_reached?(held, Clock.utc_now())

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
      {:ok, held} -> action.(socket, held)
      {:error, _reason} -> show(socket, nil, :invalid)
    end
  end

  defp confirm(socket, held) do
    case verify_held(held) do
      {:ok, :verified, verified} ->
        state =
          if MeetingState.awaiting_approval?(verified), do: :verified_request, else: :verified

        show(socket, with_meeting(held, verified), state)

      {:ok, :already_verified, current} ->
        show(socket, with_meeting(held, current), :already_verified)

      # Released, by the deadline or by an exit that won a race: the stored
      # row says which.
      {:error, :expired} ->
        load(socket)

      # Still held: its work could not be queued, so a retry may succeed.
      {:error, :not_scheduled} ->
        socket
        |> show(held, :failed)
        |> put_flash(
          :error,
          dgettext(
            "booking_manage",
            "We could not confirm your booking just now. Please try again."
          )
        )

      # Still held, but a reschedule request has voided the slot's time: a
      # retry is refused while the request is pending, and the seat lapses
      # at its deadline unless the request is cleared before then.
      {:error, :slot_void} ->
        socket
        |> show(held, :failed)
        |> put_flash(
          :error,
          dgettext(
            "booking_manage",
            "The organiser is changing this meeting's time, so your booking cannot be confirmed for now. You can try again while your place is held."
          )
        )
    end
  end

  # Somebody got there first (a confirmation in another tab, the expiry
  # job): show what the booking actually became.
  defp release(socket, held) do
    case release_held(held) do
      {:ok, released} -> show(socket, with_meeting(held, released), :released)
      {:error, :not_awaiting_verification} -> load(socket)
    end
  end

  defp verify_held({:seat, seat, _slot}), do: EmailVerification.verify_seat(seat)
  defp verify_held(meeting), do: EmailVerification.verify(meeting)

  defp release_held({:seat, seat, _slot}), do: EmailVerification.release_seat(seat)
  defp release_held(meeting), do: EmailVerification.release(meeting)

  # What the page shows after an action: a seat's outcome is read against
  # its slot as the domain returned it, a meeting's is the meeting returned.
  defp with_meeting({:seat, seat, _slot}, %MeetingSchema{} = slot),
    do: {:seat, seat, slot}

  defp with_meeting({:seat, _seat, _slot} = held, _released_seat), do: held
  defp with_meeting(_meeting, current), do: current

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
