defmodule TymeslotWeb.Themes.Shared.ReschedulePin do
  @moduledoc """
  Pins a reschedule to the meeting type of the booking it is moving.

  A reschedule is not a choice of meeting type. `Tymeslot.Bookings.Reschedule`
  re-reads the type from the meeting on submit, so whichever card the booker
  clicks is discarded either way. Left as a list of every type the organiser
  offers, the overview step asks a question whose answer cannot be used: the
  booker picks "In person", the booking moves as the video meeting it has
  always been, and nothing says so.

  Pinned, the step shows one card — the meeting's own — already selected, so it
  confirms what is being moved and "next" is a single click. It also keeps a
  guest who only wants a different time from being shown the host's entire
  catalogue on the way.

  The pin is the *only* meeting-type resolver a reschedule uses. `LiveHelpers.Mount`
  applies it on every `handle_params`, and the schedule and booking entries
  defer to it rather than resolving the slug in the URL. That is what a stale
  or hand-edited link like `/:username/<another-slug>?reschedule_meeting_uid=…`
  turns on: resolved by slug, the page offers slots against one type's schedule
  while the submit validates against the meeting's own.

  A group participant moving their own seat (`:reschedule_seat_token`) is
  pinned the same way, to the type of the meeting their seat is on:
  `Tymeslot.Bookings.RescheduleSeat` books the move against that type
  whatever the page showed, so offering another type's slots would only
  promise times the move is not checked against.

  A whole booking whose type the host has deleted since resolves to `nil`, and
  then the choice is a real one: the page falls back to the full list, as
  before. A seat whose type is gone cannot move at all, and never reaches the
  pin (`SeatMoveLink` turns it away); a seat on another organiser's meeting
  (a hand-edited username) has no type either and is not pinned, and its
  submit is refused.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_navigate: 2, push_patch: 2, put_flash: 3]

  alias Tymeslot.Bookings.Refusal
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Scheduling.RescheduleContext
  alias Tymeslot.Scheduling.SeatMoveContext
  alias Tymeslot.Scheduling.ThemeFlow
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Shared.PathHandlers
  alias TymeslotWeb.Themes.Shared.SeatMoveLink

  require Refusal

  @doc """
  Loads the booking the page's `:reschedule_meeting_uid` names, once, into
  `:reschedule_context` (`Tymeslot.Scheduling.ThemeFlow.reschedule_context/2`):
  the meeting type, location, form values and answers the page starts from all
  read it rather than looking the meeting up again.

  A booking the rules refuse leaves no context and its reason in
  `:reschedule_refusal`, for `leave_if_refused/1`; a uid naming no meeting of
  this organiser leaves neither, and the page books afresh. A page with no uid
  is cleared of both.

  Run whenever the page applies its URL, so a booking cancelled or moved on
  since is caught there, as on arrival. Between URL changes the page keeps
  what it loaded; the submit asks the rules again whatever the page holds.
  """
  @spec load_context(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load_context(
        %{assigns: %{reschedule_meeting_uid: uid, organizer_user_id: user_id}} = socket
      )
      when is_binary(uid) and is_integer(user_id) do
    case ThemeFlow.reschedule_context(uid, user_id) do
      {:ok, context} -> assign_context(socket, context, nil)
      {:error, reason} when Refusal.is_refusal(reason) -> assign_context(socket, nil, reason)
      {:error, _not_the_organisers} -> assign_context(socket, nil, nil)
    end
  end

  def load_context(socket), do: assign_context(socket, nil, nil)

  defp assign_context(socket, context, refusal) do
    socket
    |> assign(:reschedule_context, context)
    |> assign(:reschedule_refusal, refusal)
  end

  @doc """
  The meeting type a reschedule is committed to, or `nil` when this is not a
  reschedule, a whole booking's type no longer exists, or a seat is on
  another organiser's meeting.

  Always read from the seat or the booking the page loaded from its link
  (`:seat_move_context`, `:reschedule_context`). It deliberately does not read `:meeting_type` back
  off the socket: the schedule entry assigns that from the URL slug, so
  trusting it would let a stale link pin the page to a type the meeting is
  not, and then present it as the one being moved. A seat token wins over a
  uid, as it does on submit (`Tymeslot.Bookings.Orchestrator`).
  """
  @spec meeting_type(Phoenix.LiveView.Socket.t()) :: map() | nil
  def meeting_type(socket) do
    case socket.assigns do
      %{seat_move_context: %SeatMoveContext{meeting_type: meeting_type}} -> meeting_type
      %{reschedule_context: %RescheduleContext{meeting_type: meeting_type}} -> meeting_type
      _neither -> nil
    end
  end

  @doc """
  Sends a page whose URL names a booking the rules no longer let be moved
  (cancelled, completed, expired, under way or over) on to a fresh booking,
  telling the visitor why, rather than letting them fill in a form whose
  submit can only be refused. The manage page's reschedule link refuses the
  same bookings at mount. Reads the refusal `load_context/1` found; a page
  with no reschedule uid, or one naming a booking that can still move, is
  left as it is.
  """
  @spec leave_if_refused(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def leave_if_refused(%{assigns: %{reschedule_refusal: reason}} = socket)
      when Refusal.is_refusal(reason) do
    socket
    |> put_flash(:error, BookingErrorMessage.message(reason))
    |> push_navigate(to: PathHandlers.restart_path(socket))
  end

  def leave_if_refused(socket), do: socket

  @doc """
  Marks the page as pinned to `meeting_type`: it is the only one offered, and
  it arrives selected.
  """
  @spec pin(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def pin(socket, meeting_type) do
    slug = MeetingTypes.effective_slug(meeting_type)

    socket
    |> assign(:meeting_types, [meeting_type])
    |> assign(:meeting_type_pinned, true)
    |> assign(:selected_duration, slug)
    |> assign(:duration, slug)
  end

  @doc "Marks the page as offering a real choice of meeting type."
  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket), do: assign(socket, :meeting_type_pinned, false)

  @doc """
  Marks a page that stops being pinned as offering a real choice again: the
  organiser's catalogue, which the pin had replaced with the one type being
  moved, is re-resolved the way the mount resolves it, which is also what
  keeps a demo organiser whole (its types are synthesised by the overlay
  rather than stored, so no query could rebuild them).

  On a page that opens on the overview (`on_overview?`), the pinned type
  stays selected only if the catalogue offers it: one it no longer lists
  (deactivated since, or private) would leave a selection no card matches,
  and a "next" that books it. A page on a type's own link keeps it, as that
  link is how such a type is reached. A page that was not pinned is only
  marked so.
  """
  @spec unpin(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def unpin(socket, on_overview?) do
    if pinned?(socket) do
      socket
      |> clear()
      |> OrganizerHelpers.handle_username_resolution(socket.assigns[:username_context])
      |> then(&if(on_overview?, do: drop_selection_off_catalogue(&1), else: &1))
    else
      clear(socket)
    end
  end

  defp drop_selection_off_catalogue(socket) do
    offered = Enum.map(socket.assigns[:meeting_types] || [], &MeetingTypes.effective_slug/1)

    if socket.assigns[:selected_duration] in offered,
      do: socket,
      else: assign(socket, selected_duration: nil, duration: nil, meeting_type: nil)
  end

  @doc """
  Leaves the reschedule behind: the page is booking afresh again.

  "Schedule Another Meeting" restarts the flow in place, without navigating, so
  `handle_params/3` never runs a second time and nothing else drops the
  reschedule context. Left on the socket, `:reschedule_meeting_uid` is what the
  next submit still dispatches on, and the booker moves the meeting they have
  just moved rather than getting the new one they asked for.

  The same holds for a seat move: a `:reschedule_seat_token` left behind
  routes every later submit back through the seat move, where the spent token
  can only fail as "already cancelled or moved". With the token gone, the
  next booking entry builds a blank form rather than the seat's prefilled one.

  Clearing `:is_rescheduling` is not enough on its own: the uid is what the
  orchestrator receives, and the pin has replaced `:meeting_types` with the one
  type being moved, which `unpin/2` puts right for the route the booking
  starts again on.
  """
  @spec abandon(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def abandon(socket) do
    socket
    |> assign(:reschedule_meeting_uid, nil)
    |> assign_context(nil, nil)
    |> SeatMoveLink.clear()
    |> assign(:is_rescheduling, false)
    |> unpin(socket.assigns[:entered_via_overview] == true)
  end

  @doc """
  Takes an abandoned reschedule out of the address bar.

  `abandon/1` forgets it on the socket, but the URL still names it: reloaded
  or shared, the page would start the reschedule over (or, its seat link
  now spent, turn the visitor away). Patched to the host's booking page as a
  fresh booking, the URL says what the page now is. A page whose URL carries
  no reschedule is left alone.
  """
  @spec drop_from_url(Phoenix.LiveView.Socket.t(), :overview | :schedule) ::
          Phoenix.LiveView.Socket.t()
  def drop_from_url(socket, route \\ :overview) do
    if PathHandlers.reschedule_in_url?(socket),
      do: push_patch(socket, to: PathHandlers.restart_path(socket, route)),
      else: socket
  end

  @doc "Whether the page is pinned to a single meeting type."
  @spec pinned?(Phoenix.LiveView.Socket.t()) :: boolean()
  def pinned?(socket), do: socket.assigns[:meeting_type_pinned] == true

  @doc """
  The duration slug a `:select_duration` event may settle on.

  A pinned page offers one card and no choice, so the payload is ignored
  rather than trusted. The event is still reachable without the card — it is
  the client that decides what to push — and a foreign slug would otherwise
  land in `:selected_duration`, where it is no longer one of `:meeting_types`
  and so fails the step's own validation, wedging "next" with no card selected.
  """
  @spec selected_duration(Phoenix.LiveView.Socket.t(), String.t() | nil) :: String.t() | nil
  def selected_duration(socket, duration) do
    if pinned?(socket), do: socket.assigns[:selected_duration], else: duration
  end
end
