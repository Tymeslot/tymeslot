defmodule Tymeslot.Auth.RegistrationAnnouncement do
  @moduledoc """
  Announces a completed registration: durably to the configured
  `:user_registered_hook`, through a retried Oban job, and to in-process
  subscribers over PubSub.

  The hook gets a job rather than the broadcast because whatever it records
  (terms acceptance, say) must not depend on a subscriber process being
  alive at the moment of sign-up. The job is enqueued inside the
  transaction that creates the account (`enqueue_hook/2`), so an account
  never exists without it; the broadcast (`announce/1`) follows the commit
  and names only the account and its sign-up provider.
  With no hook configured, only the broadcast happens.
  """

  alias Tymeslot.Infrastructure.PubSub
  alias Tymeslot.Workers.UserRegisteredHookWorker

  @doc """
  Enqueues the registration hook job for `user_id`, when a hook is
  configured. Call it inside the transaction that creates the account and
  roll the transaction back on `{:error, {:registration_hook, reason}}`, so
  the account and the job commit together or not at all.
  """
  @spec enqueue_hook(pos_integer(), map()) :: :ok | {:error, {:registration_hook, term()}}
  def enqueue_hook(user_id, metadata) do
    if Application.get_env(:tymeslot, :user_registered_hook) do
      case user_id |> UserRegisteredHookWorker.new_job(metadata) |> Oban.insert() do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, {:registration_hook, reason}}
      end
    else
      :ok
    end
  end

  @doc """
  Broadcasts the completed registration to in-process subscribers. Call it
  after the account has committed.
  """
  @spec announce(struct()) :: :ok
  def announce(user), do: PubSub.broadcast_user_registered(user)
end
