defmodule TymeslotWeb.Themes.Shared.ReschedulePin do
  @moduledoc """
  Pins a reschedule to the meeting type of the booking it is moving.

  A reschedule is not a choice of meeting type. `LiveHelpers.resolve_meeting_type/2`
  answers with the meeting's own type whenever a reschedule uid is set, and
  `Tymeslot.Bookings.Reschedule` re-reads the type from the meeting on submit,
  so whichever card the booker clicks is discarded twice over. Left as a list of
  every type the organiser offers, the overview step asks a question whose
  answer cannot be used: the booker picks "In person", the booking moves as the
  video meeting it has always been, and nothing says so.

  Pinned, the step shows one card — the meeting's own — already selected, so it
  confirms what is being moved and "next" is a single click. It also keeps a
  guest who only wants a different time from being shown the host's entire
  catalogue on the way, which is what `entered_via_overview` already refuses to
  do for a direct link.

  A type the host has deleted since the booking resolves to `nil`, and then the
  choice is a real one: the page falls back to the full list, as before.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Scheduling.ThemeFlow

  @doc """
  The meeting type a reschedule is committed to, or `nil` when this is not a
  reschedule or its type no longer exists.

  Resolved once: `LiveHelpers.handle_param_updates/2` runs on every
  `handle_params`, and the type cannot change underneath a reschedule.
  """
  @spec meeting_type(Phoenix.LiveView.Socket.t()) :: map() | nil
  def meeting_type(%{assigns: %{meeting_type: %{} = meeting_type}} = socket) do
    if reschedule?(socket), do: meeting_type
  end

  def meeting_type(socket) do
    with true <- reschedule?(socket),
         uid when is_binary(uid) <- socket.assigns[:reschedule_meeting_uid],
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
  @spec apply(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply(socket, meeting_type) do
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

  defp reschedule?(socket), do: is_binary(socket.assigns[:reschedule_meeting_uid])
end
