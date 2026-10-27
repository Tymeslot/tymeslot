defmodule Tymeslot.Workers.UserRegisteredHookWorker do
  @moduledoc """
  Runs the configured `:user_registered_hook` for one completed
  registration (see `Tymeslot.Auth.Behaviours.UserRegisteredHook`). An
  `{:error, reason}`, a raise or an exit from the hook is retried with
  Oban's backoff, and any of them on the final attempt raises an admin alert.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: 3600, keys: [:user_id]]

  alias Tymeslot.Infrastructure.AdminAlerts

  @doc """
  Builds the job for `user_id`. Only JSON-safe metadata values are kept, so
  a stray tuple or struct cannot make the insert fail.
  """
  @spec new_job(pos_integer(), map()) :: Oban.Job.changeset()
  def new_job(user_id, metadata) do
    new(%{"user_id" => user_id, "metadata" => json_safe(metadata)})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args} = job) do
    case Application.get_env(:tymeslot, :user_registered_hook) do
      nil ->
        :ok

      hook ->
        case run_hook(hook, user_id, Map.get(args, "metadata", %{}), job) do
          {:error, reason} = error ->
            if final_attempt?(job), do: alert_exhausted(user_id, reason)
            error

          result ->
            result
        end
    end
  end

  # A raise (a dropped database connection inside the hook, say) or an exit
  # (a `GenServer.call` timing out, a linked process dying) is the likeliest
  # way the hook runs out of attempts, so it alerts on the final one too; it
  # is re-raised or re-exited so Oban records and retries it as before.
  defp run_hook(hook, user_id, metadata, job) do
    hook.on_user_registered(user_id, metadata)
  rescue
    exception ->
      if final_attempt?(job), do: alert_exhausted(user_id, exception)
      reraise exception, __STACKTRACE__
  catch
    :exit, reason ->
      if final_attempt?(job), do: alert_exhausted(user_id, {:exit, reason})
      :erlang.raise(:exit, reason, __STACKTRACE__)
  end

  defp final_attempt?(job), do: job.attempt >= job.max_attempts

  # Whatever the hook records (the terms acceptance, say) is lost for good
  # once Oban stops retrying, so an operator has to act on it by hand.
  defp alert_exhausted(user_id, reason) do
    AdminAlerts.report(:user_registered_hook_failed,
      summary: "Registration hook failed on its final attempt; its record is missing",
      reason: reason,
      context: %{user_id: user_id}
    )
  end

  defp json_safe(metadata) when is_map(metadata) do
    for {key, value} <- metadata,
        is_atom(key) or is_binary(key),
        is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value),
        into: %{},
        do: {to_string(key), value}
  end

  defp json_safe(_metadata), do: %{}
end
