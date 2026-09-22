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

  The pin is the *only* meeting-type resolver a reschedule uses. `LiveHelpers`
  applies it on every `handle_params`, and the schedule and booking entries
  defer to it rather than resolving the slug in the URL. That is what a stale
  or hand-edited link like `/:username/<another-slug>?reschedule_meeting_uid=…`
  turns on: resolved by slug, the page offers slots against one type's schedule
  while the submit validates against the meeting's own.

  A type the host has deleted since the booking resolves to `nil`, and then the
  choice is a real one: the page falls back to the full list, as before.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Scheduling.ThemeFlow

  @doc """
  The meeting type a reschedule is committed to, or `nil` when this is not a
  reschedule or its type no longer exists.

  Always resolved from the uid. It deliberately does not read `:meeting_type`
  back off the socket to save the query: the schedule entry assigns that from
  the URL slug, so trusting it would let a stale link pin the page to a type
  the meeting is not, and then present it as the one being moved.
  """
  @spec meeting_type(Phoenix.LiveView.Socket.t()) :: map() | nil
  def meeting_type(socket) do
    with uid when is_binary(uid) <- socket.assigns[:reschedule_meeting_uid],
         user_id when is_integer(user_id) <- socket.assigns[:organizer_user_id] do
      ThemeFlow.resolve_meeting_type_for_reschedule(uid, user_id)
    else
      _not_a_reschedule_with_a_type -> nil
    end
  end

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
