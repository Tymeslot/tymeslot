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

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.MeetingRequestLive.View

  @impl Phoenix.LiveView
  def render(assigns), do: View.page(assigns)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, dgettext("booking", "Booking request"))
     |> assign(:decline_reason, "")
     |> assign(:token, nil)
     |> assign(:choosing, :approve)
     |> assign(:meeting, nil)
     |> assign(:state, :invalid)}
  end

  # The token read and the meeting fetch it drives are both database reads
  # (`ApprovalToken.verify/1`, then `load_request/2`), so they wait for the
  # connected render rather than running again on the disconnected static one
  # a plain HTTP GET already triggered.
  @impl Phoenix.LiveView
  def handle_params(%{"token" => token} = params, _uri, socket) do
    socket =
      socket
      |> assign(:token, token)
      |> assign(:choosing, intent_from(params))

    socket = if connected?(socket), do: load_request(socket, token), else: socket

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # `?intent=decline` opens the page with the decline note already showing, so
  # a host who has decided does not have to hunt for it. It is a starting
  # position, not a decision.
  defp intent_from(%{"intent" => "decline"}), do: :decline
  defp intent_from(_params), do: :approve

  defp load_request(socket, token) do
    case ApprovalToken.verify(token) do
      {:ok, meeting} ->
        assign(socket, meeting: meeting, state: state_for(meeting))

      {:error, reason} ->
        Logger.info("Rejected booking request link", reason: inspect(reason))
        assign(socket, meeting: nil, state: :invalid)
    end
  end

  # `:declined` is the host's own refusal and nothing else. `Approval.declined?/1`
  # owns that question: `status == "cancelled"` does not answer it, since the
  # invitee can withdraw a held request themselves, and neither does
  # `approval_resolved_at`, which an approval stamps as well — a meeting the
  # host approved and later cancelled would otherwise be shown to the invitee
  # as having been refused. A completed meeting or a legacy
  # `reschedule_requested` row has no accurate message here either, so
  # everything but a genuine decline falls back to the same "not currently
  # answerable" wording used for an unrecognised token, rather than borrowing
  # the decline copy.
  defp state_for(meeting) do
    cond do
      MeetingState.awaiting_approval?(meeting) and lapsed?(meeting) -> :lapsed
      MeetingState.awaiting_approval?(meeting) -> :awaiting
      meeting.status == "confirmed" -> :approved
      meeting.status == "expired" -> :expired
      Approval.declined?(meeting) -> :declined
      true -> :invalid
    end
  end

  # True once the answer deadline has passed but the row is still
  # `"awaiting_approval"` — the window between the deadline and the expiry
  # sweep (or a losing race against it) actually running. Distinguishing this
  # from `:awaiting` keeps the page from showing a past deadline as if it
  # were still ahead, and from offering Approve/Decline on a request that is
  # already effectively closed.
  defp lapsed?(%{approval_deadline_at: nil}), do: false

  defp lapsed?(%{approval_deadline_at: deadline}),
    do: DateTime.compare(deadline, Clock.utc_now()) == :lt

  @impl Phoenix.LiveView
  def handle_event("choose", %{"intent" => intent}, socket) do
    {:noreply, assign(socket, :choosing, if(intent == "decline", do: :decline, else: :approve))}
  end

  def handle_event("approve", _params, socket) do
    {:noreply, answer(socket, socket.assigns.meeting, &Approval.approve/1, :approved)}
  end

  # `reason` comes from the submitted form, not a live-tracked assign: the
  # decline note is only read once, at submission, so there is nothing to
  # keep in sync on every keystroke.
  def handle_event("decline", params, socket) do
    reason = params |> Map.get("reason", "") |> sanitize_reason()

    {:noreply, answer(socket, socket.assigns.meeting, &Approval.decline(&1, reason), :declined)}
  end

  # PostgreSQL rejects a null byte even though it is valid UTF-8, and this
  # reason is free text a host can paste from anywhere. Params are attacker
  # shaped, not form shaped: `reason[x]=y` arrives as a map, so anything that
  # is not a binary is treated as no reason at all rather than raising out of
  # `String.replace/3`.
  defp sanitize_reason(reason) when is_binary(reason),
    do: String.replace(reason, "\x00", "")

  defp sanitize_reason(_reason), do: ""

  # No held request to act on — a bad token, or the owner check in
  # `load_request/2` failed — so the page is already showing the invalid
  # state. Nothing to rate-limit or answer.
  defp answer(socket, nil, _action, _success_state), do: socket

  defp answer(socket, meeting, action, success_state) do
    case RateLimiter.check_meeting_approval_rate_limit(ClientIP.get(socket)) do
      :ok ->
        apply_answer(socket, meeting, action, success_state)

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
