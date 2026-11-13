defmodule Tymeslot.Availability.BookabilityOverrideSchema do
  @moduledoc """
  The organiser's choice for one calendar event: whether it stops guests
  booking its time (`busy`), whatever its calendar marks it. The event is
  named by its integration and its cached uid (`provider_calendar_events.uid`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          calendar_integration_id: integer() | nil,
          provider_uid: String.t() | nil,
          busy: boolean() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "event_bookability_overrides" do
    field :user_id, :id
    field :calendar_integration_id, :id
    field :provider_uid, :string
    field :busy, :boolean

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(override, attrs) do
    override
    |> cast(attrs, [:user_id, :calendar_integration_id, :provider_uid, :busy])
    |> validate_required([:user_id, :calendar_integration_id, :provider_uid, :busy])
    |> unique_constraint([:user_id, :calendar_integration_id, :provider_uid],
      name: :event_bookability_overrides_user_event_index
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:calendar_integration_id)
  end
end
