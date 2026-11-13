defmodule TymeslotWeb.Themes.Shared.VerificationResend do
  @moduledoc """
  The confirmation step's "Resend email", for a booking waiting for its
  attendee to confirm their email address, handled once for every theme.

  The booking's uid must never reach the attendee before verification, so
  the button carries nothing: the meeting's id is kept in the socket's own
  assigns (`:verification_meeting_id`) from the moment the booking is made
  (`remember/2`), never rendered, never in the address, and the handler
  reads the meeting again by that id. The domain decides everything else
  (`Tymeslot.Meetings.EmailVerification.resend/1`: still held, the deadline,
  the per-booking cap); this module maps its answer to the
  `:verification_resend` state that
  `TymeslotWeb.Themes.Shared.Components.VerificationNotice.resend/1` renders.

  Each press is charged to the client's address (`:booking_verification_resend`)
  before the domain is asked. After a resend the button stays disabled for a
  short cooldown, so a double press cannot spend two of the booking's resends;
  the server refuses the event meanwhile, as it does once nothing more can be
  sent.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @cooldown_ms 20_000

  # A press in these states is refused without asking anyone: a resend just
  # went out, or there is nothing left to resend.
  @refused_states [:sent, :limit_reached, :expired, :used]

  @doc """
  Records a booking just made: its id when it waits for verification, so
  the confirmation step can offer a resend, and no id otherwise. Clears the
  outcome of any earlier press.
  """
  @spec remember(Socket.t(), map()) :: Socket.t()
  def remember(socket, meeting) do
    id = if MeetingState.awaiting_verification?(meeting), do: meeting.id

    assign(socket, verification_meeting_id: id, verification_resend: nil)
  end

  @doc "Forgets the booking, for a fresh start on the same page."
  @spec forget(Socket.t()) :: Socket.t()
  def forget(socket), do: assign(socket, verification_meeting_id: nil, verification_resend: nil)

  @doc "Handles a press of \"Resend email\"."
  @spec resend(Socket.t()) :: {:noreply, Socket.t()}
  def resend(socket) do
    id = socket.assigns[:verification_meeting_id]

    if is_nil(id) or socket.assigns[:verification_resend] in @refused_states do
      {:noreply, socket}
    else
      case RateLimiter.check(:booking_verification_resend, ClientIP.get(socket)) do
        :ok -> {:noreply, resend_for(socket, id)}
        {:error, :rate_limited, _message} -> {:noreply, show(socket, :rate_limited)}
        {:error, _no_usable_client} -> {:noreply, show(socket, :retry)}
      end
    end
  end

  @doc "Ends the cooldown after a resend: the button may be pressed again."
  @spec ready(Socket.t()) :: {:noreply, Socket.t()}
  def ready(%{assigns: %{verification_resend: :sent}} = socket),
    do: {:noreply, show(socket, nil)}

  def ready(socket), do: {:noreply, socket}

  # A booking gone altogether was deleted after it expired unverified.
  defp resend_for(socket, id) do
    case Meetings.get_meeting(id) do
      {:ok, meeting} -> outcome(socket, EmailVerification.resend(meeting))
      {:error, :not_found} -> show(socket, :expired)
    end
  end

  defp outcome(socket, {:ok, _meeting}) do
    Process.send_after(self(), :verification_resend_ready, @cooldown_ms)
    show(socket, :sent)
  end

  defp outcome(socket, {:error, :limit_reached}), do: show(socket, :limit_reached)
  defp outcome(socket, {:error, :expired}), do: show(socket, :expired)
  defp outcome(socket, {:error, :not_awaiting_verification}), do: show(socket, :used)
  defp outcome(socket, {:error, :not_scheduled}), do: show(socket, :retry)

  defp show(socket, state), do: assign(socket, verification_resend: state)
end
