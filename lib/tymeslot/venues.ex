defmodule Tymeslot.Venues do
  @moduledoc """
  The organiser's saved in-person locations ("venues" in code, "locations"
  in the UI).

  An in-person location option on a meeting type lists venues by id, the
  way a video option lists video integrations. With one, the booker is told
  where the meeting is; with several, the booker picks; with none, the
  address is arranged after booking. The meeting records the venue it was
  booked at (`meetings.venue_id`) and a one-line snapshot of it
  (`meetings.location`, from `display/1`), so editing or deleting a venue
  later never rewrites a past meeting.

  Every function acting on a venue is scoped to its owner.
  """

  alias Tymeslot.Venues.VenueQueries
  alias Tymeslot.Venues.VenueSchema

  @typedoc "A venue as the booking page and the location resolver see it."
  @type choice :: %{id: integer(), name: String.t(), description: String.t() | nil}

  @doc """
  The owner's venues in the owner's order (position, then id). This is the
  one order venues appear in everywhere: the Locations page, the editor's
  pills, a location's stored `venue_ids` and the booker's picker.
  """
  @spec list_venues(integer()) :: [VenueSchema.t()]
  def list_venues(user_id) when is_integer(user_id), do: VenueQueries.list_for_user(user_id)

  @doc """
  One of the owner's venues. `{:error, :not_found}` for a venue that does not
  exist, belongs to someone else, or an id that is not a number.
  """
  @spec get_venue(integer(), integer() | String.t()) ::
          {:ok, VenueSchema.t()} | {:error, :not_found}
  def get_venue(user_id, id) when is_integer(user_id) do
    with venue_id when is_integer(venue_id) <- parse_id(id),
         %VenueSchema{} = venue <- VenueQueries.get_for_user(user_id, venue_id) do
      {:ok, venue}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "A changeset for the add and edit forms."
  @spec change_venue(VenueSchema.t(), map()) :: Ecto.Changeset.t()
  def change_venue(venue \\ %VenueSchema{}, attrs \\ %{}), do: VenueSchema.changeset(venue, attrs)

  @doc "Creates a venue owned by `user_id`, last in the owner's order."
  @spec create_venue(integer(), map()) :: {:ok, VenueSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_venue(user_id, attrs) when is_integer(user_id) do
    %VenueSchema{user_id: user_id, position: VenueQueries.next_position(user_id)}
    |> VenueSchema.changeset(attrs)
    |> VenueQueries.insert_venue()
  end

  @doc """
  Puts the owner's venues in the order of `ordered_ids`, as dragged on the
  Locations page. Ids may arrive as strings from the client; ones that are
  not numbers, or not the owner's venues, are ignored.
  """
  @spec reorder_venues(integer(), [integer() | String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reorder_venues(user_id, ordered_ids) when is_integer(user_id) and is_list(ordered_ids) do
    ids =
      ordered_ids
      |> Enum.map(&parse_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    VenueQueries.reorder(user_id, ids)
  end

  @doc "Renames or re-describes a venue. Past meetings keep their snapshot."
  @spec update_venue(VenueSchema.t(), map()) ::
          {:ok, VenueSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_venue(%VenueSchema{} = venue, attrs) do
    venue
    |> VenueSchema.changeset(attrs)
    |> VenueQueries.update_venue()
  end

  @doc "Deletes a venue."
  @spec delete_venue(VenueSchema.t()) :: {:ok, VenueSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_venue(%VenueSchema{} = venue), do: VenueQueries.delete_venue(venue)

  @doc """
  Whether every id in `ids` is one of the owner's venues. True for no ids at
  all: an in-person location listing none is valid.
  """
  @spec owns_all?(integer(), [integer()]) :: boolean()
  def owns_all?(_user_id, []), do: true

  def owns_all?(user_id, ids) when is_integer(user_id) and is_list(ids) do
    unique = Enum.uniq(ids)
    VenueQueries.count_owned(user_id, unique) == length(unique)
  end

  @doc "A venue as the booking page and the resolver see it."
  @spec to_choice(VenueSchema.t()) :: choice()
  def to_choice(%VenueSchema{} = venue),
    do: %{id: venue.id, name: venue.name, description: venue.description}

  @doc """
  The one-line string written to a meeting's `location`, and so to its
  calendar event and emails.

  The name alone when there is no description, otherwise
  `"Name (description)"`, with the description's line breaks folded to
  `", "` so a calendar's LOCATION field stays on one line.
  """
  @spec display(%{name: String.t(), description: String.t() | nil}) :: String.t()
  def display(%{name: name, description: description}) do
    case fold_lines(description) do
      "" -> name
      folded -> "#{name} (#{folded})"
    end
  end

  defp fold_lines(nil), do: ""

  defp fold_lines(description) do
    description
    |> String.split(~r/\R/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp parse_id(id) when is_integer(id) and id > 0, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil
end
