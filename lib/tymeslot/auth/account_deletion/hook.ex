defmodule Tymeslot.Auth.AccountDeletion.Hook do
  @moduledoc """
  Calls the configured `Tymeslot.Auth.Behaviours.AccountDeletionHook`, so the
  rest of the deletion code never reads the config key or decides which
  failures matter.

  `requested/2` and `restored/1` are best-effort: an error, a raise, an exit or a throw
  is logged and `:ok` returned, because neither may undo what the user just did.
  `deleted/1` returns the hook's error, which stops the deletion.
  `purge_protected_user_ids/0` fails closed: an error, a raise, an exit, a
  throw or a malformed answer comes back as `{:error, _}`, on which the purge
  deletes nothing.
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

  @spec purge_protected_user_ids() :: {:ok, [integer()]} | {:error, term()}
  def purge_protected_user_ids do
    hook = hook()

    if hook && Code.ensure_loaded?(hook) && function_exported?(hook, :purge_protected_user_ids, 0) do
      validate_protected_ids(hook.purge_protected_user_ids())
    else
      {:ok, []}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  defp validate_protected_ids({:ok, ids} = ok) when is_list(ids) do
    if Enum.all?(ids, &is_integer/1), do: ok, else: {:error, {:invalid_protected_ids, ids}}
  end

  defp validate_protected_ids({:error, _reason} = error), do: error
  defp validate_protected_ids(other), do: {:error, {:invalid_return, other}}

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
