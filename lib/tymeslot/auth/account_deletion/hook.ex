defmodule Tymeslot.Auth.AccountDeletion.Hook do
  @moduledoc """
  Calls the configured `Tymeslot.Auth.Behaviours.AccountDeletionHook`, so the
  rest of the deletion code never reads the config key or decides which
  failures matter.

  `requested/2` and `restored/1` are best-effort: an error, a raise, an exit or a throw
  is logged and `:ok` returned, because neither may undo what the user just did.
  `deleted/1` returns the hook's error, which stops the deletion.
  """

  require Logger

  alias Tymeslot.Auth.Behaviours.AccountDeletionHook
  alias Tymeslot.Infrastructure.Logging.LogFormat

  @spec requested(pos_integer(), AccountDeletionHook.feedback()) :: :ok
  def requested(user_id, feedback),
    do: best_effort(:on_deletion_requested, [user_id, feedback], user_id)

  @spec restored(pos_integer()) :: :ok
  def restored(user_id), do: best_effort(:on_deletion_restored, [user_id], user_id)

  @spec deleted(integer()) :: :ok | {:error, term()}
  def deleted(user_id) do
    case hook() do
      nil -> :ok
      hook -> hook.on_account_deletion(user_id)
    end
  end

  defp best_effort(callback, args, user_id) do
    case hook() do
      nil -> :ok
      hook -> hook |> apply(callback, args) |> log_unless_ok(callback, user_id)
    end
  rescue
    exception -> log_failure(callback, user_id, exception)
  catch
    :exit, reason -> log_failure(callback, user_id, {:exit, reason})
    :throw, value -> log_failure(callback, user_id, {:throw, value})
  end

  defp log_unless_ok(:ok, _callback, _user_id), do: :ok

  defp log_unless_ok({:error, reason}, callback, user_id),
    do: log_failure(callback, user_id, reason)

  defp log_failure(callback, user_id, reason) do
    Logger.error("Account deletion hook failed; carrying on",
      callback: callback,
      user_id: user_id,
      reason: LogFormat.reason(reason)
    )

    :ok
  end

  defp hook, do: Application.get_env(:tymeslot, :account_deletion_hook)
end
