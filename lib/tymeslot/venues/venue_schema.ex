defmodule Tymeslot.Venues.VenueSchema do
  @moduledoc """
  A saved in-person location: somewhere the owner meets people.

  In-person location options on the owner's meeting types reference venues
  by id (`Tymeslot.MeetingTypes.LocationOption.venue_ids`). The UI calls a
  venue a "location"; the code does not, because `LocationOption`,
  `location_kind` and `meetings.location` already mean something else.

  `description` is free text: the address plus anything else a booker needs
  ("3rd floor, ring the bell"), over several lines if the owner likes.
  `Tymeslot.Venues.display/1` folds it onto one line for the meeting.

  `position` is the owner's order for their venues, the one order used
  everywhere venues are listed (see `Tymeslot.Venues.reorder_venues/2`).

  `user_id` and `position` are not cast: the context sets them, so no
  submitted attrs can move a venue onto another account or out of order.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema

  @name_max_length 120
  @description_max_length 500

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          position: integer(),
          user: UserSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "venues" do
    field(:name, :string)
    field(:description, :string)
    field(:position, :integer, default: 0)

    belongs_to(:user, UserSchema)

    timestamps(type: :utc_datetime)
  end

  @doc "Builds the changeset for creating or editing a venue."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(venue, attrs) do
    venue
    |> cast(attrs, [:name, :description])
    |> update_change(:name, &clean/1)
    |> update_change(:description, &clean/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @name_max_length)
    |> validate_length(:description, max: @description_max_length)
    |> unique_constraint(:name, name: :venues_user_id_lower_name_index)
    |> foreign_key_constraint(:user_id)
  end

  @doc "The longest name a venue may have."
  @spec name_max_length() :: pos_integer()
  def name_max_length, do: @name_max_length

  @doc "The longest description a venue may have."
  @spec description_max_length() :: pos_integer()
  def description_max_length, do: @description_max_length

  # PostgreSQL rejects null bytes even though they are valid UTF-8, and a
  # value that is only whitespace means the field was left empty.
  defp clean(value) when is_binary(value) do
    case value |> String.replace("\x00", "") |> String.trim() do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp clean(value), do: value
end
