defmodule Tymeslot.Venues do
  @moduledoc """
  The organiser's saved in-person locations ("venues" in code, "locations"
  in the UI).

  An in-person location option on a meeting type lists venues by id, the
  way a video option lists video integrations. With one, the booker is told
  where the meeting is; with several, the booker picks; with none, the
  address is arranged after booking (never for a group type, whose address
  is fixed in advance). The meeting records the venue it was
  booked at (`meetings.venue_id`) and a one-line snapshot of it
  (`meetings.location`, from `display/1`), so editing or deleting a venue
  later never rewrites a past meeting.

  Every function acting on a venue is scoped to its owner.
  """

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Venues.VenueQueries
  alias Tymeslot.Venues.VenueSchema

  # The largest value a PostgreSQL bigint id can hold; a larger one cannot
  # even be sent as a query parameter.
  @max_id 9_223_372_036_854_775_807

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

  @doc """
  Renames or re-describes a venue. Past meetings keep their snapshot.

  `{:error, :not_found}` when the venue was deleted since it was loaded, say
  from another tab while its edit form was open.
  """
  @spec update_venue(VenueSchema.t(), map()) ::
          {:ok, VenueSchema.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_venue(%VenueSchema{} = venue, attrs) do
    venue
    |> VenueSchema.changeset(attrs)
    |> VenueQueries.update_venue()
    |> not_found_if_stale()
  end

  defp not_found_if_stale({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    case Keyword.get(errors, :id) do
      {_message, opts} -> if opts[:stale], do: {:error, :not_found}, else: {:error, changeset}
      nil -> {:error, changeset}
    end
  end

  defp not_found_if_stale(result), do: result

  @doc """
  Deletes a venue, even while meeting types list it, unless it is the
  address of a group type.

  In one transaction, the venue is first taken off every in-person location
  of the owner's meeting types that lists it (the other venues keep their
  order, and nothing else about the location changes), then deleted. A
  location whose only venue it was is left listing none, and so means "the
  address is arranged after booking" from then on; the Locations page warns
  about those first (`meeting_types_left_without/1`).

  A group type cannot be left like that: everyone booked into a slot shares
  one meeting, so its address is fixed in advance
  (`Tymeslot.MeetingTypes.GroupLocationRule`). While the venue is the only
  one of a group type's location, the delete is refused with
  `{:error, {:group_meeting_types, meeting_types}}` naming them, and nothing
  changes; the organiser gives those types another venue first
  (`blocking_group_types/1` says which, before a delete is tried). The
  rewrite itself refuses the same case on the locked rows
  (`MeetingTypeSchema.without_venue_changeset/2`), so a type turned into a
  group type meanwhile is caught too.

  Meetings already booked there keep their `location` text and their
  `address_to_arrange` flag; the foreign key clears their `venue_id`.

  `{:error, :not_found}` when the venue is already gone.
  """
  @spec delete_venue(VenueSchema.t()) ::
          {:ok, VenueSchema.t()}
          | {:error,
             :not_found | {:group_meeting_types, [MeetingTypeSchema.t()]} | Ecto.Changeset.t()}
  def delete_venue(%VenueSchema{} = venue) do
    case blocking_group_types(venue) do
      [] -> venue |> delete_in_transaction() |> group_types_from_rewrite()
      group_types -> {:error, {:group_meeting_types, group_types}}
    end
  end

  defp delete_in_transaction(%VenueSchema{id: id, user_id: user_id} = venue) do
    Repo.transaction(fn ->
      with {:ok, _rewritten} <- MeetingTypes.remove_venue_from_locations(user_id, id),
           {:ok, deleted} <- VenueQueries.delete_venue(venue) do
        deleted
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The rewrite refused a group type that became one after the check above.
  defp group_types_from_rewrite(
         {:error, %Ecto.Changeset{data: %MeetingTypeSchema{} = meeting_type} = changeset}
       ) do
    if Keyword.has_key?(changeset.errors, :locations),
      do: {:error, {:group_meeting_types, [meeting_type]}},
      else: {:error, changeset}
  end

  defp group_types_from_rewrite(result), do: result

  @doc """
  The owner's group meeting types, by name, whose location lists `venue` as
  its only venue, and which therefore keep it from being deleted
  (`delete_venue/1`).
  """
  @spec blocking_group_types(VenueSchema.t()) :: [MeetingTypeSchema.t()]
  def blocking_group_types(%VenueSchema{id: id, user_id: user_id}),
    do: MeetingTypes.group_types_left_without_venue(user_id, id)

  @doc """
  The venue a meeting about to be written refers to, or nil when it has
  been deleted since the booking was resolved.

  Called inside the transaction that writes the meeting, and holds the
  venue until that transaction ends (`VenueQueries.hold/1`), so a delete
  cannot slip in between this answer and the write. Unscoped: the venue id
  comes from the organiser's own meeting type, resolved for this booking.
  """
  @spec hold_for_meeting(integer() | nil) :: integer() | nil
  def hold_for_meeting(nil), do: nil
  def hold_for_meeting(id) when is_integer(id), do: if(VenueQueries.hold(id), do: id)

  @doc """
  The owner's meeting types whose locations list `venue`, by name: the ones
  a delete changes.
  """
  @spec meeting_types_using(VenueSchema.t()) :: [MeetingTypeSchema.t()]
  def meeting_types_using(%VenueSchema{id: id, user_id: user_id}),
    do: MeetingTypes.list_using_venue(user_id, id)

  @doc """
  Of `meeting_types_using/1`, those a delete would leave with an in-person
  location listing no venue, by name, because `venue` is that location's
  only one.
  """
  @spec meeting_types_left_without(VenueSchema.t()) :: [MeetingTypeSchema.t()]
  def meeting_types_left_without(%VenueSchema{id: id, user_id: user_id}),
    do: MeetingTypes.left_without_venue(user_id, id)

  @doc """
  Venue id to the number of the owner's meeting types listing it, for the
  Locations page. Venues no meeting type lists are absent.
  """
  @spec usage_counts(integer()) :: %{integer() => pos_integer()}
  def usage_counts(user_id) when is_integer(user_id), do: MeetingTypes.venue_usage_counts(user_id)

  @doc """
  Whether every id in `ids` is one of the owner's venues. Ids may arrive as
  strings; one that is not a valid id makes the answer false. True for no
  ids at all: an in-person location listing none is valid.
  """
  @spec owns_all?(integer(), [integer() | String.t()]) :: boolean()
  def owns_all?(_user_id, []), do: true

  def owns_all?(user_id, ids) when is_integer(user_id) and is_list(ids) do
    parsed = Enum.map(ids, &parse_id/1)

    if Enum.member?(parsed, nil) do
      false
    else
      unique = Enum.uniq(parsed)
      VenueQueries.count_owned(user_id, unique) == length(unique)
    end
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
  @spec display(%{
          :name => String.t(),
          :description => String.t() | nil,
          optional(atom()) => any()
        }) :: String.t()
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

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_id, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} when parsed > 0 and parsed <= @max_id -> parsed
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil
end
