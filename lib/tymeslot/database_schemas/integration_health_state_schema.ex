defmodule Tymeslot.DatabaseSchemas.IntegrationHealthStateSchema do
  @moduledoc """
  Schema for persisting integration health state across restarts.

  Stores the current health status, failure/success counts, backoff timing,
  and notification tracking for each calendar and video integration.

  The unique index on `[integration_type, integration_id]` ensures one record
  per integration, regardless of type.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          integration_type: String.t() | nil,
          integration_id: integer() | nil,
          user: Tymeslot.Auth.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          user_id: integer() | nil,
          status: String.t(),
          failures: non_neg_integer(),
          successes: non_neg_integer(),
          backoff_ms: pos_integer(),
          last_check_at: DateTime.t() | nil,
          last_error_class: String.t() | nil,
          became_unhealthy_at: DateTime.t() | nil,
          notification_sent_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "integration_health_states" do
    field(:integration_type, :string)
    field(:integration_id, :integer)
    belongs_to(:user, Tymeslot.Auth.UserSchema)
    field(:status, :string, default: "healthy")
    field(:failures, :integer, default: 0)
    field(:successes, :integer, default: 0)
    field(:backoff_ms, :integer, default: 1_800_000)
    field(:last_check_at, :utc_datetime_usec)
    field(:last_error_class, :string)
    field(:became_unhealthy_at, :utc_datetime_usec)
    field(:notification_sent_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :integration_type,
      :integration_id,
      :user_id,
      :status,
      :failures,
      :successes,
      :backoff_ms,
      :last_check_at,
      :last_error_class,
      :became_unhealthy_at,
      :notification_sent_at
    ])
    |> validate_required([:integration_type, :integration_id, :user_id, :status])
    |> unique_constraint([:integration_type, :integration_id])
  end

  @doc """
  Changeset for upsert operations (conflict updates).
  Does not require `user_id` or `status` since only specific fields are replaced.
  """
  @spec upsert_changeset(t(), map()) :: Ecto.Changeset.t()
  def upsert_changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :integration_type,
      :integration_id,
      :user_id,
      :status,
      :failures,
      :successes,
      :backoff_ms,
      :last_check_at,
      :last_error_class,
      :became_unhealthy_at,
      :notification_sent_at
    ])
    |> validate_required([:integration_type, :integration_id])
    |> unique_constraint([:integration_type, :integration_id])
  end
end
