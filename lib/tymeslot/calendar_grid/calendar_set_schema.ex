defmodule Tymeslot.CalendarGrid.CalendarSetSchema do
  @moduledoc """
  A calendar set: a named group of calendars the organiser applies with its
  digit (`position`, 1 to 9) on the calendar. `members` lists what the
  set shows (see `Member`). Which set is active lives on the calendar
  preferences (`active_calendar_set_id`); see
  `Tymeslot.CalendarGrid.CalendarSets`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.CalendarGrid.CalendarSetSchema.Member

  @positions 1..9
  @max_name 40
  @max_members 200

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          name: String.t() | nil,
          position: integer() | nil,
          members: [Member.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_sets" do
    belongs_to :user, Tymeslot.Auth.UserSchema
    field :name, :string
    field :position, :integer
    embeds_many :members, Member, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc "The positions a set can take: the digits that apply it."
  @spec positions() :: Range.t()
  def positions, do: @positions

  @doc "A set's name, digit, owner and (when given) members."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(set, attrs) do
    set
    |> cast(attrs, [:user_id, :name, :position])
    |> update_change(:name, &clean_name/1)
    |> validate_required([:user_id, :name, :position])
    |> validate_length(:name, max: @max_name)
    |> validate_inclusion(:position, @positions)
    |> cast_embed(:members)
    |> validate_length(:members, max: @max_members)
    |> check_constraint(:position, name: :calendar_sets_position_range)
    |> unique_constraint([:user_id, :position], name: :calendar_sets_user_id_position_index)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Replaces a set's members and nothing else."
  @spec members_changeset(t(), [map()]) :: Ecto.Changeset.t()
  def members_changeset(set, members) do
    set
    |> cast(%{members: Enum.map(members, &member_params/1)}, [])
    |> cast_embed(:members)
    |> validate_length(:members, max: @max_members)
  end

  @doc "A member, struct or map, as changeset params."
  @spec member_params(map()) :: map()
  def member_params(%{integration_id: integration_id, calendar_id: calendar_id}),
    do: %{integration_id: integration_id, calendar_id: calendar_id}

  # PostgreSQL rejects null bytes; the name is trimmed after removing them,
  # so a name of only those is blank.
  defp clean_name(name) when is_binary(name),
    do: name |> String.replace("\u0000", "") |> String.trim()

  defp clean_name(name), do: name
end
