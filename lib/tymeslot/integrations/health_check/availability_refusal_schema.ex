defmodule Tymeslot.Integrations.HealthCheck.AvailabilityRefusalSchema do
  @moduledoc """
  How many times one organiser's availability could not be computed within one
  clock hour, because at least one of their selected calendars could not be
  read (`:some_calendars_unavailable` or `:all_calendars_unavailable`).

  The availability path fails closed on those reasons, so each one is a booking
  page, a booking submit or a poll check that offered the visitor nothing. One
  row per user per hour, incremented in place, is the smallest record that lets
  `Tymeslot.Integrations.HealthCheck.Alerting` count affected organisers over a
  window without keeping an event per page view. Rows are pruned by
  `Tymeslot.Workers.DataRetentionWorker`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          bucket_start: DateTime.t() | nil,
          refusals: pos_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_availability_refusals" do
    belongs_to(:user, Tymeslot.Auth.UserSchema)
    field(:bucket_start, :utc_datetime)
    field(:refusals, :integer, default: 1)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:user_id, :bucket_start, :refusals])
    |> validate_required([:user_id, :bucket_start, :refusals])
    |> validate_number(:refusals, greater_than: 0)
    |> foreign_key_constraint(:user_id)
  end
end
