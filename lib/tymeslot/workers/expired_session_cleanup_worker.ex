defmodule Tymeslot.Workers.ExpiredSessionCleanupWorker do
  @moduledoc """
  Daily maintenance job to remove expired user sessions from the database.

  This keeps the user_sessions table and indexes lean for better performance
  and reduces storage overhead across primaries, replicas, and backups.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]
  require Logger

  alias Tymeslot.DatabaseQueries.UserSessionQueries

  @impl Oban.Worker
  def perform(_job) do
    case UserSessionQueries.cleanup_expired_sessions() do
      {deleted_count, _} ->
        Logger.info("Expired session cleanup completed", deleted_count: deleted_count)
        :ok
    end
  rescue
    error ->
      Logger.error("Expired session cleanup failed", error: inspect(error))
      # Don't retry aggressively; log and acknowledge to avoid repeated failures
      :ok
  end
end
