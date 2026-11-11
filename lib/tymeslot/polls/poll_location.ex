defmodule Tymeslot.Polls.PollLocation do
  @moduledoc """
  Where a poll's meeting will be held.

  A poll may have a location of its own (`PollSchema`'s `location_kind` and
  the field that goes with it): a video call on one of the host's video
  integrations, one of their saved venues (`Tymeslot.Venues`), or a place
  they typed in. Without one, it takes the location of its meeting type,
  resolved as a booking that changes nothing would resolve it
  (`Tymeslot.MeetingTypes.resolve_location/2`): the type's first location,
  its first provider or venue. Without either, it has none.

  That one location (`effective/1`) is what everybody sees: the invitation
  emails and the voting page name it, and confirming the poll creates the
  meeting there (`meeting_params/1`), a video call with its room.

  The host's form sends the choice as one value (`parse_choice/2`):
  `"video:<id>"`, `"venue:<id>"`, `"custom"` with the typed place beside it,
  or `""` for none.
  """

  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Venues

  @type kind :: :video | :in_person | :phone | :custom

  @typedoc """
  The location in force: what kind of place it is, the line naming it (none
  for a video call, whose link only exists once the meeting does), and the
  venue or video integration behind it.
  """
  @type t :: %{
          kind: kind(),
          place: String.t() | nil,
          venue_id: integer() | nil,
          video_integration_id: integer() | nil
        }

  @fields [:location_kind, :location_details, :venue_id, :video_integration_id]

  @doc """
  The poll attributes for a choice as the host's form sends it, with the
  place typed in for `"custom"`. Anything else, a forged value among it,
  is no location of the poll's own.
  """
  @spec parse_choice(String.t() | nil, String.t() | nil) :: map()
  def parse_choice(choice, details) do
    case String.split(choice || "", ":", parts: 2) do
      ["video", id] -> with_id(:video, :video_integration_id, id)
      ["venue", id] -> with_id(:in_person, :venue_id, id)
      ["custom"] -> attrs(:custom, %{location_details: details})
      _none -> attrs(nil, %{})
    end
  end

  defp with_id(kind, field, raw) do
    case Integer.parse(raw) do
      {id, ""} -> attrs(kind, %{field => id})
      _forged -> attrs(nil, %{})
    end
  end

  defp attrs(kind, set),
    do: @fields |> Map.new(&{&1, nil}) |> Map.merge(set) |> Map.put(:location_kind, kind)

  @doc """
  What the host's form offers: their video integrations that are switched
  on, and their saved venues, in the order of their Locations page.
  """
  @spec options(integer()) :: %{
          videos: [%{id: integer(), name: String.t()}],
          venues: [%{id: integer(), name: String.t()}]
        }
  def options(user_id) when is_integer(user_id) do
    %{
      videos: Enum.map(Video.list_active_integrations(user_id), &%{id: &1.id, name: &1.name}),
      venues: Enum.map(Venues.list_venues(user_id), &%{id: &1.id, name: &1.name})
    }
  end

  @doc """
  The form's value for the poll's own location, and the place typed in for
  a custom one: the inverse of `parse_choice/2`.
  """
  @spec choice(PollSchema.t()) :: {String.t(), String.t()}
  def choice(%PollSchema{location_kind: :video, video_integration_id: id}) when is_integer(id),
    do: {"video:#{id}", ""}

  def choice(%PollSchema{location_kind: :in_person, venue_id: id}) when is_integer(id),
    do: {"venue:#{id}", ""}

  def choice(%PollSchema{location_kind: :custom, location_details: details}),
    do: {"custom", details || ""}

  def choice(%PollSchema{}), do: {"", ""}

  @doc """
  Whether the venue or video integration `attrs` sets (see `parse_choice/2`)
  is `user_id`'s to hold a meeting at: a venue of theirs, or a video
  integration of theirs that is switched on. A location `poll` already has
  passes as it is, so saving its other details never fails on an
  integration switched off since.
  """
  @spec check(integer(), map(), PollSchema.t() | nil) :: :ok | {:error, :location_not_found}
  def check(user_id, attrs, poll \\ nil) do
    case {value(attrs, :location_kind), value(attrs, :venue_id),
          value(attrs, :video_integration_id)} do
      {kind, venue_id, _video} when kind in [:in_person, "in_person"] ->
        check_venue(user_id, venue_id, poll)

      {kind, _venue, video_id} when kind in [:video, "video"] ->
        check_video(user_id, video_id, poll)

      _no_reference ->
        :ok
    end
  end

  defp check_venue(_user_id, id, %PollSchema{venue_id: id}) when is_integer(id), do: :ok

  defp check_venue(user_id, id, _poll) when is_integer(id) do
    case Venues.get_venue(user_id, id) do
      {:ok, _venue} -> :ok
      {:error, _not_found} -> {:error, :location_not_found}
    end
  end

  # A missing id is the changeset's to refuse.
  defp check_venue(_user_id, _id, _poll), do: :ok

  defp check_video(_user_id, id, %PollSchema{video_integration_id: id}) when is_integer(id),
    do: :ok

  defp check_video(user_id, id, _poll) when is_integer(id) do
    if Enum.any?(Video.list_active_integrations(user_id), &(&1.id == id)),
      do: :ok,
      else: {:error, :location_not_found}
  end

  defp check_video(_user_id, _id, _poll), do: :ok

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  @doc """
  The location in force for `poll`: its own, or its meeting type's, or nil.

  A venue or integration deleted since the host chose it was nilified with
  it, so the poll has no location of its own any more and falls back to its
  meeting type's.
  """
  @spec effective(PollSchema.t()) :: t() | nil
  def effective(%PollSchema{} = poll) do
    own(poll) || from_meeting_type(poll)
  end

  defp own(%PollSchema{location_kind: :video, video_integration_id: id}) when is_integer(id),
    do: %{kind: :video, place: nil, venue_id: nil, video_integration_id: id}

  defp own(%PollSchema{location_kind: :in_person, venue_id: id, user_id: user_id})
       when is_integer(id) do
    case Venues.get_venue(user_id, id) do
      {:ok, venue} ->
        %{kind: :in_person, place: Venues.display(venue), venue_id: id, video_integration_id: nil}

      {:error, _not_found} ->
        nil
    end
  end

  defp own(%PollSchema{location_kind: :custom, location_details: place})
       when is_binary(place) and place != "",
       do: %{kind: :custom, place: place, venue_id: nil, video_integration_id: nil}

  defp own(_poll), do: nil

  defp from_meeting_type(%PollSchema{meeting_type_id: nil}), do: nil

  defp from_meeting_type(%PollSchema{meeting_type_id: id, user_id: user_id}),
    do: id |> MeetingTypes.get_meeting_type(user_id) |> of_meeting_type()

  @doc """
  The location a poll on `meeting_type` takes while it has none of its own:
  the type's first location, with its first provider or venue, as a booking
  that changes nothing would get. Nil for no type, or a type whose first
  location names no place (a video location left without a provider).
  """
  @spec of_meeting_type(map() | nil) :: t() | nil
  def of_meeting_type(nil), do: nil

  def of_meeting_type(meeting_type),
    do: meeting_type |> MeetingTypes.resolve_location(%{}) |> from_resolution()

  defp from_resolution(%{location_kind: nil}), do: nil

  defp from_resolution(%{location_kind: :video} = resolution) do
    if resolution.video_integration_id,
      do: %{
        kind: :video,
        place: nil,
        venue_id: nil,
        video_integration_id: resolution.video_integration_id
      }
  end

  # A place only a booker would supply (a phone location asking for their
  # number) names nothing a poll's participants could go by.
  defp from_resolution(%{location: place}) when place in [nil, ""], do: nil

  defp from_resolution(resolution) do
    %{
      kind: resolution.location_kind,
      place: resolution.location,
      venue_id: resolution.venue_id,
      video_integration_id: nil
    }
  end

  @doc """
  What `Tymeslot.Bookings.CreateAdHoc` takes to hold the confirmed meeting
  at `location` (see `effective/1`): the place, as a venue or as the line
  naming it, and the video integration that creates its room.
  """
  @spec meeting_params(t() | nil) :: %{
          location: {:venue, integer()} | {:custom, String.t()} | nil,
          video_integration_id: integer() | nil
        }
  def meeting_params(%{kind: :video, video_integration_id: id}),
    do: %{location: nil, video_integration_id: id}

  def meeting_params(%{venue_id: id}) when is_integer(id),
    do: %{location: {:venue, id}, video_integration_id: nil}

  def meeting_params(%{place: place}) when is_binary(place) and place != "",
    do: %{location: {:custom, place}, video_integration_id: nil}

  def meeting_params(_none), do: %{location: nil, video_integration_id: nil}
end
