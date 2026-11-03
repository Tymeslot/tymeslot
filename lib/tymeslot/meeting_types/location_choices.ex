defmodule Tymeslot.MeetingTypes.LocationChoices do
  @moduledoc """
  What a booker may choose about where to meet, and how that choice resolves
  into the meeting's location fields: the video providers and venues each of
  a meeting type's locations still offers, read from the host's current
  integrations and venue library, and the resolution of a submitted choice
  against them. Reached through `Tymeslot.MeetingTypes`.
  """

  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingTypes.LocationSelection
  alias Tymeslot.Venues

  @typedoc """
  What a booker submitted about where to meet. Every key is optional, and
  each is honoured only where the host's own meeting type offers it:

    * `:option_id`, the location option chosen
    * `:phone`, the booker's number, for a phone option that asks for it
    * `:video_integration_id`, the provider picked within a video option
    * `:venue_id`, the venue picked within an in-person option
    * `:current_venue_id`, on a reschedule the meeting's own venue, kept
      when `:venue_id` is not one the option offers
  """
  @type location_choice :: %{
          optional(:option_id) => String.t() | nil,
          optional(:phone) => String.t() | nil,
          optional(:video_integration_id) => integer() | String.t() | nil,
          optional(:venue_id) => integer() | String.t() | nil,
          optional(:current_venue_id) => integer() | nil
        }

  @doc """
  Resolves a booker's location choice into the meeting fields that follow
  from it.

  A video location can outlive an integration it names: the host
  disconnected it, and the location keeps its id until the host next edits
  the meeting type. Such an id is resolved as if the location did not list
  it, so the meeting lands on the location's next listed integration, or on
  none, and is booked without a room, just as a booking on a deactivated
  integration is. A deactivated integration still resolves: the room job
  checks it when it runs, and it may be switched back on by then.

  An in-person location can likewise list a venue that has since gone. Only
  venues that still exist are offered (`location_venue_choices/1`), so the
  meeting lands on the one the booker picked while it is offered, otherwise
  on the location's first remaining venue, or on none, as a booking whose
  address is arranged afterwards.
  """
  @spec resolve_location(map() | nil, location_choice()) :: LocationSelection.resolution()
  def resolve_location(meeting_type, choice) when is_map(choice) do
    meeting_type = without_removed_video_integrations(meeting_type)

    resolution =
      LocationSelection.resolve(
        meeting_type,
        choice[:option_id],
        choice[:phone],
        choice[:video_integration_id]
      )

    venues =
      meeting_type
      |> location_venue_choices()
      |> Map.get(resolution.location_option_id, [])

    LocationSelection.place_at_venue(resolution, venues, [
      choice[:venue_id],
      choice[:current_venue_id]
    ])
  end

  # Only a stored list can name a removed integration: the option a meeting
  # type without one derives comes from its `video_integration_id`, which the
  # foreign key nils when the integration goes.
  defp without_removed_video_integrations(
         %{user_id: user_id, locations: [_first | _rest] = locations} = meeting_type
       )
       when is_integer(user_id) do
    if Enum.any?(locations, &(&1.video_integration_ids != [])) do
      held = user_id |> Video.list_integrations() |> MapSet.new(& &1.id)

      locations =
        Enum.map(locations, fn location ->
          %{
            location
            | video_integration_ids: Enum.filter(location.video_integration_ids, &(&1 in held))
          }
        end)

      %{meeting_type | locations: locations}
    else
      meeting_type
    end
  end

  defp without_removed_video_integrations(meeting_type), do: meeting_type

  @doc """
  The video providers the booker can pick between, per video location:
  a map from option id to the host's active integrations that option
  lists, in the host's order.

  An integration the host has since deactivated or deleted is left out, so
  the booker is never offered a provider that cannot create a room. A
  location left with nothing active is absent from the map.
  """
  @spec location_video_choices(map() | nil) :: %{
          String.t() => [%{id: integer(), name: String.t(), provider: String.t()}]
        }
  def location_video_choices(%{user_id: user_id} = meeting_type) when is_integer(user_id) do
    video_options =
      meeting_type |> LocationSelection.options() |> Enum.filter(&(&1.kind == :video))

    if video_options == [] do
      %{}
    else
      active =
        user_id
        |> Video.list_integrations()
        |> Enum.filter(& &1.is_active)
        |> Map.new(&{&1.id, %{id: &1.id, name: &1.name, provider: &1.provider}})

      for option <- video_options,
          choices =
            option.video_integration_ids |> Enum.map(&active[&1]) |> Enum.reject(&is_nil/1),
          choices != [],
          into: %{},
          do: {option.id, choices}
    end
  end

  def location_video_choices(_meeting_type), do: %{}

  @doc """
  The venues the booker can pick between, per in-person location: a map
  from option id to the owner's venues that option lists, as
  `Tymeslot.Venues.choice/0` maps, in the organiser's library order (the
  order dragged on the Locations page), so reordering the library reorders
  every picker. The first is the one the picker opens on.

  A venue that no longer exists, or is not the owner's, is left out, and a
  location left with none is absent from the map: its address is arranged
  after booking. Loaded once when the booking page mounts, next to
  `location_video_choices/1`, so rendering runs no query.
  """
  @spec location_venue_choices(map() | nil) :: %{String.t() => [Venues.choice()]}
  def location_venue_choices(%{user_id: user_id} = meeting_type) when is_integer(user_id) do
    in_person =
      meeting_type
      |> LocationSelection.options()
      |> Enum.filter(&(&1.kind == :in_person and &1.venue_ids != []))

    if in_person == [] do
      %{}
    else
      library = user_id |> Venues.list_venues() |> Enum.map(&Venues.to_choice/1)

      for option <- in_person,
          choices = Enum.filter(library, &(&1.id in option.venue_ids)),
          choices != [],
          into: %{},
          do: {option.id, choices}
    end
  end

  def location_venue_choices(_meeting_type), do: %{}
end
