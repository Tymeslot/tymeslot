defmodule Tymeslot.Workers.AccountDeletionCheckoutsWorker do
  @moduledoc """
  Expires the open paid checkouts of a host who has asked for their account
  to be deleted, and cancels their pending bookings
  (`Tymeslot.MeetingPayments.cancel_pending_checkouts/1`), so no attendee can
  still pay for a booking the host will never hold.

  Queued by the deletion request once its own work (the owner's notice, the
  deletion hook) is done, so a slow or failing Stripe holds none of it up.
  Unique per user while waiting or running. A host who has restored the
  account by the time it runs keeps their checkouts. A failed cancellation is
  retried; a session Stripe would not expire is only logged, since a checkout
  that completes regardless is refunded when it does.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:user_id], states: :incomplete]

  alias Tymeslot.Auth
  alias Tymeslot.MeetingPayments

  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(user_id), do: %{user_id: user_id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) when is_integer(user_id) do
    if Auth.deletion_pending?(user_id) do
      with {:ok, _cancelled} <- MeetingPayments.cancel_pending_checkouts(%{id: user_id}), do: :ok
    else
      :ok
    end
  end
end
