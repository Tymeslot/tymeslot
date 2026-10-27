defmodule Tymeslot.Workers.ExpiredSessionCleanupWorker do
  @moduledoc """
  Daily maintenance job to remove expired user sessions from the database,
  and to release email changes whose verification link has expired.

  This keeps the user_sessions table and indexes lean for better performance
  and reduces storage overhead across primaries, replicas, and backups.
  Releasing expired email changes frees their pending addresses, which are
  unique, so an abandoned change cannot hold an address indefinitely.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]
  require Logger

  alias Tymeslot.Auth.{AccountTokens, UserSessionQueries}

  @impl Oban.Worker
  def perform(_job) do
    case UserSessionQueries.cleanup_expired_sessions() do
      {deleted_count, _sessions} ->
        released_count = AccountTokens.release_expired_email_changes()

        Logger.info("Expired session cleanup completed",
          deleted_count: deleted_count,
          released_email_change_count: released_count
        )

        :ok
    end
  rescue
    error ->
      Logger.error("Expired session cleanup failed", error: error)
      {:error, Exception.message(error)}
  end
end
