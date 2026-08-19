defmodule TymeslotWeb.MeetingRequestLive do
  @moduledoc """
  Where a host answers a booking request from the link in their email.

  Reachable without a session, because the point is to answer from a phone in
  the ten seconds after reading the mail. Authorisation is the signed token
  (`Tymeslot.Meetings.ApprovalToken`), which names both the meeting and the
  organiser it was issued for; a token whose organiser no longer matches the
  meeting is refused.

  ## Nothing happens on load

  The `intent` query parameter preselects Approve or Decline but never acts.
  Mail security products and link-preview crawlers fetch every URL in an
  inbound message, so a page that approved as a side effect of being loaded
  would fill hosts' calendars with meetings they never saw. The decision is a
  `phx-click`, which arrives over the LiveView socket and no crawler sends.

  Answering twice is safe: `Tymeslot.Meetings.Approval` resolves the race in
  the database, and the loser is shown what actually happened rather than an
  error.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.MeetingRequestLive.View

  @impl Phoenix.LiveView
  def render(assigns), do: View.page(assigns)

  @impl Phoenix.LiveView
  def mount(%{"token" => token} = params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, dgettext("booking", "Booking request"))
     |> assign(:token, token)
     |> assign(:decline_reason, "")
     |> assign(:choosing, intent_from(params))
     |> load_request(token)}
  end

  # `?intent=decline` opens the page with the decline note already showing, so
  # a host who has decided does not have to hunt for it. It is a starting
  # position, not a decision.
  defp intent_from(%{"intent" => "decline"}), do: :decline
  defp intent_from(_params), do: :approve

  defp load_request(socket, token) do
    with {:ok, {meeting_id, organizer_user_id}} <- ApprovalToken.verify(token),
         {:ok, meeting} <- MeetingQueries.get_meeting(meeting_id),
         :ok <- check_owner(meeting, organizer_user_id) do
      assign(socket, meeting: meeting, state: state_for(meeting))
    else
      {:error, reason} ->
        Logger.info("Rejected booking request link", reason: inspect(reason))
        assign(socket, meeting: nil, state: :invalid)
    end
  end

  # A meeting whose organiser changed since the token was issued is not the
  # meeting this link was for.
  defp check_owner(%{organizer_user_id: id}, id), do: :ok
  defp check_owner(_meeting, _organizer_user_id), do: {:error, :organizer_mismatch}

  defp state_for(meeting) do
    cond do
      MeetingState.awaiting_approval?(meeting) -> :awaiting
      meeting.status == "confirmed" -> :approved
      meeting.status == "expired" -> :expired
      true -> :declined
    end
  end

  @impl Phoenix.LiveView
  def handle_event("choose", %{"intent" => intent}, socket) do
    {:noreply, assign(socket, :choosing, if(intent == "decline", do: :decline, else: :approve))}
  end

  def handle_event("update_reason", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, :decline_reason, reason)}
  end

  def handle_event("approve", _params, socket) do
    {:noreply, answer(socket, &Approval.approve/1, :approved)}
  end

  def handle_event("decline", _params, socket) do
    reason = socket.assigns.decline_reason

    {:noreply, answer(socket, &Approval.decline(&1, reason), :declined)}
  end

  defp answer(socket, action, success_state) do
    case RateLimiter.check_meeting_approval_rate_limit(ClientIP.get(socket)) do
      :ok ->
        apply_answer(socket, socket.assigns.meeting, action, success_state)

      {:error, :rate_limited, _message} ->
        put_flash(
          socket,
          :error,
          dgettext("booking", "Too many attempts. Try again in a moment.")
        )
    end
  end

  defp apply_answer(socket, meeting, action, success_state) do
    case action.(meeting) do
      {:ok, updated} ->
        assign(socket, meeting: updated, state: success_state)

      # Somebody — the host in another tab, or the expiry sweep — got there
      # first. Show them where the request actually ended up.
      {:error, :not_awaiting_approval} ->
        socket
        |> load_request(socket.assigns.token)
        |> put_flash(:info, dgettext("booking", "This request had already been answered."))

      {:error, :meeting_started} ->
        socket
        |> assign(:state, :too_late)
        |> put_flash(:error, dgettext("booking", "This meeting's start time has already passed."))
    end
  end
end
