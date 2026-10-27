defmodule Tymeslot.Payments.Webhooks.StripeEventSchema do
  @moduledoc """
  A Stripe webhook event the ingress has finished with, kept for
  deduplication beyond `Tymeslot.Payments.Webhooks.IdempotencyCache`'s
  in-memory tier, so a redelivery days later is still recognised. The
  platform endpoint also keeps the event's payload for debugging, until the
  retention job clears it.

  The table keeps its historical name, `webhook_events`; the outgoing
  webhooks users configure live in `Tymeslot.Webhooks`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          stripe_event_id: String.t() | nil,
          event_type: String.t() | nil,
          payload: map() | nil,
          processed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "webhook_events" do
    field :stripe_event_id, :string
    field :event_type, :string
    field :payload, :map
    field :processed_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
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
