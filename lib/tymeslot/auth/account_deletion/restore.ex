defmodule Tymeslot.Auth.AccountDeletion.Restore do
  @moduledoc """
  Cancels a pending deletion. Reached from the restore page, which only a
  signed-in account pending deletion can see, so the credentials were
  checked at sign-in.

  Under the user's row lock (the lock the deletion takes before it deletes),
  the schedule is cleared and the waiting deletion job removed; after the
  commit the deletion hook hears of it. The grace period ends at
  `deletion_scheduled_at`: once that moment has come the account is due, its
  deletion may already be running, and the restore is refused with
  `{:error, :deletion_in_progress}`, changing nothing. Reminders queued
  before the request kept running during the grace period, so nothing needs
  queuing again.
  """

  require Logger

  alias Tymeslot.Auth.AccountDeletion.Hook
  alias Tymeslot.Auth.{UserQueries, UserSchema}
  alias Tymeslot.Jobs
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AccountDeletionWorker

  @spec restore(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, :not_pending | :deletion_in_progress | term()}
  def restore(%UserSchema{id: user_id}) do
    result =
      Repo.transaction(fn ->
        with {:ok, user} <- UserQueries.get_user_for_update(user_id),
             :ok <- ensure_restorable(user, DateTime.utc_now()),
             {:ok, restored} <- UserQueries.clear_deletion_schedule(user) do
          Jobs.delete_user_jobs(AccountDeletionWorker, user_id)
          restored
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, restored} <- result do
      Hook.restored(restored.id)
      Logger.info("Account deletion cancelled; account restored", user_id: restored.id)
      {:ok, restored}
    end
  end

  defp ensure_restorable(%UserSchema{deletion_scheduled_at: nil}, _now),
    do: {:error, :not_pending}

  defp ensure_restorable(%UserSchema{deletion_scheduled_at: at}, now) do
    if due?(at, now), do: {:error, :deletion_in_progress}, else: :ok
  end

  @doc """
  Whether `user` is pending deletion with its grace period still running, so
  a restore would be accepted. A pending account whose date has passed is
  due: its deletion may be running and it can no longer be restored.
  """
  @spec restorable?(UserSchema.t(), DateTime.t()) :: boolean()
  def restorable?(%UserSchema{deletion_scheduled_at: nil}, _now), do: false
  def restorable?(%UserSchema{deletion_scheduled_at: at}, now), do: not due?(at, now)

  defp due?(at, now), do: DateTime.compare(at, now) != :gt
end
