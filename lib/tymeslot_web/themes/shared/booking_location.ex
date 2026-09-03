defmodule TymeslotWeb.Themes.Shared.BookingLocation do
  @moduledoc """
  Socket-state orchestration for the booking form's location picker.

  A meeting type offering one location has nothing to ask, so the picker is
  not rendered and the single option is simply the answer. Two or more and
  the booker chooses; a phone option can additionally ask them for their own
  number.

  The committed choice lives in `:selected_location_id`, and the booking
  submission reads it from there. Only that id crosses the wire: everything
  the choice means (the location string, its kind, which video integration
  the room is created on) is derived server-side from the host's own stored
  option by `Tymeslot.MeetingTypes.resolve_location/3`, so a forged id
  resolves to a location the host already offers rather than one the booker
  invented.

  The client-side check here is for fast feedback only. `resolve_location/3`
  re-derives everything from the meeting type on submission regardless of
  what these assigns say.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.LocationSelection

  @doc "Initial assigns for the location picker, set once at scheduling mount."
  @spec assign_defaults(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_defaults(socket) do
    socket
    |> assign(:location_options, [])
    |> assign(:selected_location_id, nil)
    |> assign(:location_phone, "")
    |> assign(:location_error, nil)
  end

  @doc """
  Loads the meeting type's locations and preselects one.

  The first option is preselected rather than leaving the choice blank: the
  booker can always change it, and a form that cannot be submitted until an
  invisible default is filled in is a worse first impression than one that
  opens on the host's preferred location.

  A selection the booker has already made survives a re-entry into the step,
  which is what makes going back to the calendar and returning non-destructive.
  """
  @spec assign_for_meeting_type(Phoenix.LiveView.Socket.t(), map() | nil) ::
          Phoenix.LiveView.Socket.t()
  def assign_for_meeting_type(socket, meeting_type) do
    options = MeetingTypes.location_options(meeting_type)
    ids = Enum.map(options, & &1.id)

    current = socket.assigns[:selected_location_id]
    selected = if current in ids, do: current, else: List.first(ids)

    socket
    |> assign(:location_options, options)
    |> assign(:selected_location_id, selected)
    |> assign(:location_error, nil)
  end

  @doc "Records the booker's choice."
  @spec choose(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def choose(socket, id) do
    if Enum.any?(socket.assigns[:location_options] || [], &(&1.id == id)) do
      socket
      |> assign(:selected_location_id, id)
      |> assign(:location_error, nil)
    else
      socket
    end
  end

  @doc "Tracks the number as the booker types it."
  @spec set_phone(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def set_phone(socket, value) do
    socket
    |> assign(:location_phone, to_string(value))
    |> assign(:location_error, nil)
  end

  @doc """
  Whether the booking form should render the picker at all.

  Never on a reschedule: `Bookings.Reschedule` moves the times and leaves
  every other field of the meeting alone, so a picker there would be a
  control that silently does nothing. Guests are hidden on a reschedule for
  the same reason.
  """
  @spec choice_required?(map()) :: boolean()
  def choice_required?(assigns) do
    assigns[:is_rescheduling] != true and length(assigns[:location_options] || []) > 1
  end

  @doc "The option currently chosen, or nil when there is nothing to choose."
  @spec selected(map()) :: LocationOption.t() | nil
  def selected(assigns) do
    Enum.find(assigns[:location_options] || [], &(&1.id == assigns[:selected_location_id]))
  end

  @doc "Whether the chosen location asks the booker for their phone number."
  @spec phone_required?(map()) :: boolean()
  def phone_required?(assigns) do
    match?(%LocationOption{kind: "phone", collect_from_guest: true}, selected(assigns))
  end

  @doc """
  The chosen location as one line, for the confirmation screen.

  Nil when there is nothing to show: an ad-hoc booking with no meeting type,
  or a reschedule, whose location is the original meeting's and not this
  session's picker state.
  """
  @spec chosen_display(map()) :: String.t() | nil
  def chosen_display(assigns) do
    cond do
      assigns[:is_rescheduling] == true -> nil
      option = selected(assigns) -> LocationSelection.display(option, assigns[:location_phone])
      true -> nil
    end
  end

  @doc """
  Whether the picker has an answer a submission can be built from.

  Read by the booking step before it shows its "verifying" state as well as
  by `validate/1`, so the button and the guard can never disagree about what
  counts as answered.
  """
  @spec complete?(map()) :: boolean()
  def complete?(assigns) do
    not (phone_required?(assigns) and blank?(assigns[:location_phone]))
  end

  @doc """
  Checks the picker before a submission is dispatched.

  Returns the socket unchanged when the choice is complete, or
  `{:error, socket}` with `:location_error` set when the chosen location
  asks for a number the booker has not given.
  """
  @spec validate(Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def validate(socket) do
    if complete?(socket.assigns) do
      {:ok, socket}
    else
      {:error,
       assign(
         socket,
         :location_error,
         dgettext("booking", "Enter the number we should call you on.")
       )}
    end
  end

  defp blank?(value), do: value |> to_string() |> String.trim() == ""
end
