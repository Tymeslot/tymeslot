defmodule Tymeslot.Payments.Webhooks.StripeEventQueries do
  @moduledoc """
  Database queries for `Tymeslot.Payments.Webhooks.StripeEventSchema`, the
  processed Stripe webhook events kept for deduplication.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Infrastructure.BatchDeleteQueries
  alias Tymeslot.Payments.Webhooks.StripeEventSchema
  alias Tymeslot.Repo

  @doc """
  The processed event with Stripe event id `stripe_event_id`, or `nil`.
  """
  @spec get_by_stripe_id(String.t()) :: StripeEventSchema.t() | nil
  def get_by_stripe_id(stripe_event_id) do
    Repo.get_by(StripeEventSchema, stripe_event_id: stripe_event_id)
  end

  @doc """
  Records a processed event. An event already recorded is left as it is.
  """
  @spec record(map()) :: {:ok, StripeEventSchema.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    %StripeEventSchema{}
    |> StripeEventSchema.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :stripe_event_id)
  end

  @doc """
  Clears the payload of every event recorded before `cutoff`, keeping the
  row for deduplication. Returns `{count, nil}`.
  """
  @spec clear_payloads_before(DateTime.t()) :: {non_neg_integer(), nil}
  def clear_payloads_before(%DateTime{} = cutoff) do
    query =
      from(e in StripeEventSchema, where: e.inserted_at < ^cutoff and not is_nil(e.payload))

    Repo.update_all(query, set: [payload: nil])
  end

  @doc """
  Deletes every event recorded before `cutoff`, in bounded batches (see
  `BatchDeleteQueries`). Returns `{count, nil}`.
  """
  @spec delete_before(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_before(%DateTime{} = cutoff) do
    BatchDeleteQueries.delete_older_than(StripeEventSchema, :inserted_at, cutoff)
  end
end
