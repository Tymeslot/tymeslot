defmodule Tymeslot.DatabaseSchemas.WebhookEventSchema do
  @moduledoc """
  Schema for storing processed webhook events for long-term deduplication.

  Provides persistent storage beyond the 24-hour ETS cache to prevent
  replay attacks and maintain audit trail of all webhook events.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          stripe_event_id: String.t() | nil,
          event_type: String.t() | nil,
          payload: map() | nil,
          processed_at: DateTime.t() | nil,
          inserted_at: NaiveDateTime.t() | nil
        }

  schema "webhook_events" do
    field :stripe_event_id, :string
    field :event_type, :string
    field :payload, :map
    field :processed_at, :utc_datetime

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating a webhook event record.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(webhook_event, attrs) do
    webhook_event
    |> cast(attrs, [:stripe_event_id, :event_type, :payload, :processed_at])
    |> validate_required([:stripe_event_id, :event_type, :processed_at])
    |> unique_constraint(:stripe_event_id)
  end
end
