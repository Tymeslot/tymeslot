defmodule TymeslotWeb.Themes.Shared.BookingLocation do
  @moduledoc """
  Socket-state orchestration for the booking form's location picker.

  A meeting type offering one location has nothing to ask, so the picker is
  not rendered and the single option is simply the answer. Two or more and
  the booker chooses; a phone option can additionally ask them for their own
  number, a video option listing several providers asks which one, and an
  in-person option listing several saved venues asks which venue. A single
  video location with several providers, or a single in-person location with
  several venues, is itself a choice, so the picker shows for it too.

  A single in-person location with at most one venue asks nothing, but the
  booking step still states it (`stated_location?/1`): its venue's name and
  address, or the note that the address is arranged after booking
  (`arranged_after_booking?/1`).

  The committed choice lives in `:selected_location_id` (and, for a video
  option, `:selected_video_id`; for an in-person option, `:selected_venue_id`),
  and the booking submission reads it from there. Only those ids cross the
  wire: everything the choice means (the location string, its kind, which
  video integration the room is created on, which venue it is at) is derived
  server-side from the host's own stored option by
  `Tymeslot.MeetingTypes.resolve_location/2`, so a forged id resolves to a
  location the host already offers rather than one the booker invented.

  The client-side check here is for fast feedback only. `resolve_location/2`
  re-derives everything from the meeting type on submission regardless of
  what these assigns say.

  ## On a reschedule

  The picker opens on the location, and the venue, the meeting already has,
  not the host's first, and the booker can move it. A meeting type with a
  single location still asks nothing, and then no choice is submitted at all
  (`submitted_option_id/1`): with nothing shown, nothing the booker did can
  have meant "move it", even when the host has since replaced the location
  the meeting was booked against.

  The venue follows the same rule within the meeting's own location
  (`:reschedule_location`). When the meeting's venue is no longer offered
  (deleted, or dropped from its location), the picker opens on the
  location's first venue, but that default is not submitted until the
  booker picks a venue (`:venue_picked`): a time-only reschedule keeps the
  meeting at the address it was booked for. Choosing another location is
  itself a move, so there the venue the picker shows is submitted.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.LocationSelection
  alias Tymeslot.Venues

  @doc "Initial assigns for the location picker, set once at scheduling mount."
  @spec assign_defaults(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_defaults(socket) do
    socket
    |> assign(:location_options, [])
    |> assign(:location_video_choices, %{})
    |> assign(:location_venue_choices, %{})
    |> assign(:selected_location_id, nil)
    |> assign(:selected_video_id, nil)
    |> assign(:selected_venue_id, nil)
    |> assign(:venue_picked, false)
    |> assign(:reschedule_location, nil)
    |> assign(:location_phone, "")
    |> assign(:location_error, nil)
  end

  @doc """
  Loads the meeting type's locations and preselects one.

  The first option is preselected rather than leaving the choice blank: the
  booker can always change it, and a form that cannot be submitted until an
  invisible default is filled in is a worse first impression than one that
  opens on the host's preferred location. The same goes for the provider of
  a video option and the venue of an in-person one.

  A selection the booker has already made survives a re-entry into the step,
  which is what makes going back to the calendar and returning non-destructive.

  `current`, on a reschedule, is the meeting's own choice
  (`%{option_id: …, phone: …, video_integration_id: …, venue_id: …}`), which
  opens the picker there instead of on the first option. A choice the meeting
  type no longer offers falls back to the first option like any other.
  """
  @spec assign_for_meeting_type(Phoenix.LiveView.Socket.t(), map() | nil, map() | nil) ::
          Phoenix.LiveView.Socket.t()
  def assign_for_meeting_type(socket, meeting_type, current \\ nil) do
    options = MeetingTypes.location_options(meeting_type)
    ids = Enum.map(options, & &1.id)

    selected =
      Enum.find([socket.assigns[:selected_location_id], current[:option_id]], &(&1 in ids)) ||
        List.first(ids)

    socket
    |> assign(:location_options, options)
    |> assign(:location_video_choices, MeetingTypes.location_video_choices(meeting_type))
    |> assign(:location_venue_choices, MeetingTypes.location_venue_choices(meeting_type))
    |> assign(:selected_location_id, selected)
    |> assign(:location_phone, seeded_phone(socket.assigns[:location_phone], current))
    |> assign(:location_error, nil)
    |> assign(:reschedule_location, reschedule_location(current))
    |> assign_selected_video([socket.assigns[:selected_video_id], current[:video_integration_id]])
    |> assign_selected_venue(socket.assigns)
  end

  # The meeting's own option and venue on a reschedule, which the venue
  # picker returns to and `submitted_venue_id/1` compares against.
  defp reschedule_location(%{} = current),
    do: %{option_id: current[:option_id], venue_id: current[:venue_id]}

  defp reschedule_location(nil), do: nil

  # The provider the video picker opens on: the first of `preferred` the
  # chosen option offers (the booker's own earlier pick, then the meeting's
  # on a reschedule), else the option's first. Nil when the chosen option is
  # not a video call.
  defp assign_selected_video(socket, preferred) do
    ids = Enum.map(video_choices(socket.assigns), & &1.id)
    assign(socket, :selected_video_id, Enum.find(preferred, &(&1 in ids)) || List.first(ids))
  end

  # The venue the venue picker opens on, among those the chosen option
  # offers: the venue the booker picked (`before` is the assigns being
  # replaced), then the meeting's own on a reschedule, then the one shown
  # before, else the option's first. Nil when the option offers no venue.
  #
  # It counts as picked (see `submitted_venue_id/1`) when it is the booker's
  # pick or the meeting's own venue; a fallback never does.
  defp assign_selected_venue(socket, before) do
    picked = if before[:venue_picked] == true, do: before[:selected_venue_id]
    meeting_venue_id = socket.assigns[:reschedule_location][:venue_id]
    ids = Enum.map(venue_choices(socket.assigns), & &1.id)

    selected =
      Enum.find([picked, meeting_venue_id, before[:selected_venue_id]], &(&1 in ids)) ||
        List.first(ids)

    socket
    |> assign(:selected_venue_id, selected)
    |> assign(:venue_picked, not is_nil(selected) and selected in [picked, meeting_venue_id])
  end

  # A number the booker has typed this session wins over the one on the
  # meeting, for the same reason the selection does.
  defp seeded_phone(phone, %{phone: stored}) when phone in [nil, ""] and is_binary(stored),
    do: stored

  defp seeded_phone(phone, _current), do: phone || ""

  @doc "Applies one of the picker's relayed events to the socket."
  @spec apply_event(
          Phoenix.LiveView.Socket.t(),
          :select_location | :select_video_provider | :select_venue | :location_phone,
          term()
        ) :: Phoenix.LiveView.Socket.t()
  def apply_event(socket, :select_location, id), do: choose(socket, id)
  def apply_event(socket, :select_video_provider, id), do: choose_video(socket, id)
  def apply_event(socket, :select_venue, id), do: choose_venue(socket, id)
  def apply_event(socket, :location_phone, value), do: set_phone(socket, value)

  @doc "Records the booker's choice."
  @spec choose(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def choose(socket, id) do
    if Enum.any?(socket.assigns[:location_options] || [], &(&1.id == id)) do
      socket
      |> assign(:selected_location_id, id)
      |> assign(:location_error, nil)
      |> assign_selected_video([socket.assigns[:selected_video_id]])
      |> assign_selected_venue(socket.assigns)
    else
      socket
    end
  end

  @doc "Records the video provider the booker picked within the chosen option."
  @spec choose_video(Phoenix.LiveView.Socket.t(), String.t() | integer()) ::
          Phoenix.LiveView.Socket.t()
  def choose_video(socket, id) do
    case Enum.find(video_choices(socket.assigns), &(to_string(&1.id) == to_string(id))) do
      nil -> socket
      choice -> assign(socket, :selected_video_id, choice.id)
    end
  end

  @doc "Records the venue the booker picked within the chosen option."
  @spec choose_venue(Phoenix.LiveView.Socket.t(), String.t() | integer()) ::
          Phoenix.LiveView.Socket.t()
  def choose_venue(socket, id) do
    case Enum.find(venue_choices(socket.assigns), &(to_string(&1.id) == to_string(id))) do
      nil ->
        socket

      choice ->
        socket
        |> assign(:selected_venue_id, choice.id)
        |> assign(:venue_picked, true)
    end
  end

  @doc """
  The providers the booker can pick between for the chosen option, or `[]`
  when it is not a video call.
  """
  @spec video_choices(map()) :: [map()]
  def video_choices(assigns) do
    Map.get(assigns[:location_video_choices] || %{}, assigns[:selected_location_id], [])
  end

  @doc "Whether the chosen option asks the booker which video provider to use."
  @spec video_choice_required?(map()) :: boolean()
  def video_choice_required?(assigns), do: length(video_choices(assigns)) > 1

  @doc """
  The venues the chosen option offers, or `[]` when it is not in person or
  offers none.
  """
  @spec venue_choices(map()) :: [Venues.choice()]
  def venue_choices(assigns) do
    Map.get(assigns[:location_venue_choices] || %{}, assigns[:selected_location_id], [])
  end

  @doc "Whether the chosen option asks the booker which venue."
  @spec venue_choice_required?(map()) :: boolean()
  def venue_choice_required?(assigns), do: length(venue_choices(assigns)) > 1

  @doc "Tracks the number as the booker types it."
  @spec set_phone(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def set_phone(socket, value) do
    socket
    |> assign(:location_phone, to_string(value))
    |> assign(:location_error, nil)
  end

  @doc """
  Whether the booking form should render the picker at all: only when there
  is something to choose, between locations, between the providers of a
  video location, or between the venues of an in-person one, on a new
  booking and a reschedule alike.
  """
  @spec choice_required?(map()) :: boolean()
  def choice_required?(assigns) do
    length(assigns[:location_options] || []) > 1 or
      several?(assigns[:location_video_choices]) or
      several?(assigns[:location_venue_choices])
  end

  defp several?(choices), do: Enum.any?(Map.values(choices || %{}), &(length(&1) > 1))

  @doc """
  The option id a submission carries.

  On a reschedule, only a choice the booker was actually shown: a hidden
  picker's default would otherwise move a meeting whose host has replaced its
  location since it was booked. See the module doc.
  """
  @spec submitted_option_id(map()) :: String.t() | nil
  def submitted_option_id(assigns) do
    if assigns[:is_rescheduling] == true and not choice_required?(assigns),
      do: nil,
      else: assigns[:selected_location_id]
  end

  @doc """
  The video provider a submission carries: the booker's pick within the
  chosen option, or nil when the option is not a video call or nothing was
  submitted for it. The server honours it only if the option lists it.
  """
  @spec submitted_video_id(map()) :: integer() | nil
  def submitted_video_id(assigns) do
    if submitted_option_id(assigns) && video_choices(assigns) != [],
      do: assigns[:selected_video_id]
  end

  @doc """
  The venue a submission carries: the booker's pick within the chosen
  option, or nil when the option offers no venue or nothing was submitted
  for it. The server honours it only if the option still offers it.

  On a new booking that is whatever the picker shows, its default included,
  and so it is on a reschedule to another location, which is a move the
  booker made. Within the meeting's own location it is only a venue the
  booker picked, or the meeting's own that the picker opened on: the
  default the picker fell back to, when the meeting's venue is no longer
  offered, would otherwise move the meeting to a venue nobody chose. See the
  module doc.
  """
  @spec submitted_venue_id(map()) :: integer() | nil
  def submitted_venue_id(assigns) do
    if submitted_option_id(assigns) && venue_choices(assigns) != [] && venue_chosen?(assigns),
      do: assigns[:selected_venue_id]
  end

  defp venue_chosen?(%{is_rescheduling: true} = assigns) do
    assigns[:venue_picked] == true or
      assigns[:selected_location_id] != assigns[:reschedule_location][:option_id]
  end

  defp venue_chosen?(_assigns), do: true

  @doc "The option currently chosen, or nil when there is nothing to choose."
  @spec selected(map()) :: LocationOption.t() | nil
  def selected(assigns) do
    Enum.find(assigns[:location_options] || [], &(&1.id == assigns[:selected_location_id]))
  end

  @doc "The venue currently chosen within the chosen option, or nil."
  @spec selected_venue(map()) :: Venues.choice() | nil
  def selected_venue(assigns) do
    Enum.find(venue_choices(assigns), &(&1.id == assigns[:selected_venue_id]))
  end

  @doc "Whether the chosen location asks the booker for their phone number."
  @spec phone_required?(map()) :: boolean()
  def phone_required?(assigns) do
    match?(%LocationOption{kind: "phone", collect_from_guest: true}, selected(assigns))
  end

  @doc """
  Whether this booking's in-person location has no venue, so the page says
  the address will be arranged after booking. False when nothing is being
  submitted, as on a reschedule that asked nothing: that meeting keeps the
  location it has.
  """
  @spec arranged_after_booking?(map()) :: boolean()
  def arranged_after_booking?(assigns) do
    not is_nil(submitted_option_id(assigns)) and in_person?(assigns) and
      venue_choices(assigns) == []
  end

  @doc """
  Whether the booking step states a single in-person location that asks
  nothing, with its venue or the arranged-after-booking note.
  """
  @spec stated_location?(map()) :: boolean()
  def stated_location?(assigns) do
    not is_nil(submitted_option_id(assigns)) and not choice_required?(assigns) and
      in_person?(assigns)
  end

  defp in_person?(assigns), do: match?(%LocationOption{kind: "in_person"}, selected(assigns))

  @doc """
  The chosen location as one line, for the confirmation screen: the chosen
  venue's `Tymeslot.Venues.display/1` for an in-person location with one,
  otherwise the option's own line.

  Nil when there is nothing to show: an ad-hoc booking with no meeting type,
  a reschedule that asked nothing, whose location is the original meeting's
  and not this session's picker state, or a reschedule whose venue the booker
  did not pick, which the server resolves rather than the picker.
  """
  @spec chosen_display(map()) :: String.t() | nil
  def chosen_display(assigns) do
    cond do
      is_nil(submitted_option_id(assigns)) -> nil
      venue_choices(assigns) != [] -> submitted_venue_display(assigns)
      option = selected(assigns) -> with_provider(option, assigns)
      true -> nil
    end
  end

  defp submitted_venue_display(assigns) do
    with id when is_integer(id) <- submitted_venue_id(assigns),
         %{} = venue <- selected_venue(assigns) do
      Venues.display(venue)
    else
      _nothing_submitted -> nil
    end
  end

  # The provider is named only when the booker picked it: with one on offer
  # it adds nothing the option's label does not already say.
  defp with_provider(option, assigns) do
    display = LocationSelection.display(option, assigns[:location_phone])

    case video_choice_required?(assigns) &&
           Enum.find(video_choices(assigns), &(&1.id == assigns[:selected_video_id])) do
      %{name: name} -> "#{display} (#{name})"
      _none -> display
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
