defmodule Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema do
  @moduledoc """
  Schema for persisting integration health state across restarts.

  Stores the current health status, failure/success counts, backoff timing,
  and notification tracking for each calendar and video integration.

  The unique index on `[integration_type, integration_id]` ensures one record
  per integration, regardless of type.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Integrations.Shared.IntegrationTypes

  @typedoc "An integration's health, as the monitor last assessed it."
  @type status :: :healthy | :degraded | :unhealthy

  @typedoc "How the last failed probe was classified."
  @type error_class :: :transient | :hard

  @type t :: %__MODULE__{
          id: integer() | nil,
          integration_type: IntegrationTypes.kind() | nil,
          integration_id: integer() | nil,
          user: Tymeslot.Auth.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          user_id: integer() | nil,
          status: status(),
          failures: non_neg_integer(),
          consecutive_hard_failures: non_neg_integer(),
          consecutive_sync_failures: non_neg_integer(),
          successes: non_neg_integer(),
          backoff_ms: pos_integer(),
          last_check_at: DateTime.t() | nil,
          last_error_class: error_class() | nil,
          became_unhealthy_at: DateTime.t() | nil,
          notification_sent_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # How often a healthy integration is probed, and the backoff a new or
  # recovered integration starts at.
  @check_interval_ms :timer.minutes(30)

  # The values repeat `IntegrationTypes.kinds/0` rather than calling it: a
  # call here would make this schema depend on that module at compile time,
  # and through it on both integration contexts. The schema test pins the two
  # lists together.
  schema "integration_health_states" do
    field(:integration_type, Ecto.Enum, values: [:calendar, :video])
    field(:integration_id, :integer)
    belongs_to(:user, Tymeslot.Auth.UserSchema)
    field(:status, Ecto.Enum, values: [:healthy, :degraded, :unhealthy], default: :healthy)
    field(:failures, :integer, default: 0)
    field(:consecutive_hard_failures, :integer, default: 0)
    field(:consecutive_sync_failures, :integer, default: 0)
    field(:successes, :integer, default: 0)
    field(:backoff_ms, :integer, default: @check_interval_ms)
    field(:last_check_at, :utc_datetime_usec)
    field(:last_error_class, Ecto.Enum, values: [:transient, :hard])
    field(:became_unhealthy_at, :utc_datetime_usec)
    field(:notification_sent_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime)
  end

  @doc "How often a healthy integration is probed, in milliseconds."
  @spec check_interval_ms() :: pos_integer()
  def check_interval_ms, do: @check_interval_ms

  # `integration_type`, `status` and `last_error_class` are `Ecto.Enum`s, so
  # every writer, the raw `update_all` in
  # `IntegrationHealthStateQueries.update_fields/3` included, can only dump
  # one of their atoms; the database check constraints close each set for
  # anything written outside Ecto.
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
      :consecutive_hard_failures,
      :consecutive_sync_failures,
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
end
