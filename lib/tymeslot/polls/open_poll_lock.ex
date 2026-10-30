defmodule Tymeslot.Polls.OpenPollLock do
  @moduledoc """
  The transaction every write to an open poll runs in: cancelling, editing,
  removing a participant, inviting, resending a link.

  The poll is read under the row lock confirmation takes
  (`Tymeslot.Polls.Confirm`), so a poll confirmed after the caller loaded its
  page is seen as confirmed here and refused, rather than written over.
  Subscribers are told once the write has committed.
  """

  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollQueries, PollSchema}
  alias Tymeslot.Repo

  @doc """
  Runs `fun` on the user's open poll, locked, in a transaction.

  `fun` gets the locked open poll and returns `{:ok, value}` or
  `{:error, reason}`, which rolls the transaction back and is returned. A
  poll the user does not own is `{:error, :not_found}`, and one that is
  confirmed or cancelled `{:error, :not_open}`. On success subscribers are
  notified and `{:ok, value}` is returned.
  """
  @spec with_locked(Ecto.UUID.t(), integer(), (PollSchema.t() ->
                                                 {:ok, value} | {:error, reason})) ::
          {:ok, value} | {:error, :not_found | :not_open | reason}
        when value: term(), reason: term()
  def with_locked(id, user_id, fun) do
    result =
      Repo.transaction(fn ->
        with %PollSchema{status: :open} = poll <- PollQueries.lock_for_user(id, user_id),
             {:ok, updated} <- fun.(poll) do
          {poll.id, updated}
        else
          nil -> Repo.rollback(:not_found)
          %PollSchema{} -> Repo.rollback(:not_open)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {poll_id, updated}} <- result do
      Polls.broadcast_update(poll_id)
      {:ok, updated}
    end
  end
end
