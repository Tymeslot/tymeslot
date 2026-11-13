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
  sent. The cooldown belongs to the booking it was started for: its timer is
  kept in `:verification_resend_cooldown` and carries a token of its own, so a
  leftover timer from an earlier booking on the same page never ends a later
  booking's cooldown, and forgetting the booking cancels it. A resend that
  used up the booking's last one still shows that it was sent, and its
  cooldown ends in `:limit_reached` rather than offering the button again.
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

    socket
    |> forget()
    |> assign(verification_meeting_id: id)
  end

  @doc "Forgets the booking, for a fresh start on the same page, and stops its cooldown."
  @spec forget(Socket.t()) :: Socket.t()
  def forget(socket) do
    case socket.assigns[:verification_resend_cooldown] do
      {timer, _token, _then} -> Process.cancel_timer(timer)
      nil -> :ok
    end

    assign(socket,
      verification_meeting_id: nil,
      verification_resend: nil,
      verification_resend_cooldown: nil
    )
  end

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

  @doc """
  Ends the cooldown started with `token`: the button may be pressed again,
  unless that resend was the booking's last, when the state becomes
  `:limit_reached`. A token from any other cooldown (an earlier booking's)
  changes nothing.
  """
  @spec ready(Socket.t(), reference()) :: {:noreply, Socket.t()}
  def ready(%{assigns: %{verification_resend_cooldown: {_timer, token, then}}} = socket, token) do
    {:noreply,
     socket
     |> assign(verification_resend_cooldown: nil)
     |> show(then)}
  end

  def ready(socket, _stale_token), do: {:noreply, socket}

  # A booking gone altogether was deleted after it expired unverified.
  defp resend_for(socket, id) do
    case Meetings.get_meeting(id) do
      {:ok, meeting} -> outcome(socket, EmailVerification.resend(meeting))
      {:error, :not_found} -> show(socket, :expired)
    end
  end

  defp outcome(socket, {:ok, meeting}) do
    token = make_ref()
    timer = Process.send_after(self(), {:verification_resend_ready, token}, @cooldown_ms)
    then = if EmailVerification.resends_left(meeting) == 0, do: :limit_reached

    socket
    |> assign(verification_resend_cooldown: {timer, token, then})
    |> show(:sent)
  end

  defp outcome(socket, {:error, :limit_reached}), do: show(socket, :limit_reached)
  defp outcome(socket, {:error, :expired}), do: show(socket, :expired)
  defp outcome(socket, {:error, :not_awaiting_verification}), do: show(socket, :used)
  defp outcome(socket, {:error, :not_scheduled}), do: show(socket, :retry)

  defp show(socket, state), do: assign(socket, verification_resend: state)
end
