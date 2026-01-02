#!/usr/bin/env elixir

# Script to manually clean up stuck Oban jobs

require Logger
alias Tymeslot.Workers.ObanMaintenanceWorker

Logger.info("Starting manual cleanup of stuck Oban jobs...")

# Perform the cleanup
case ObanMaintenanceWorker.perform(%Oban.Job{args: %{"manual" => true}}) do
  {:ok, result} ->
    Logger.info("Cleanup completed successfully", result: result)
    Logger.info("Stuck jobs cleaned: #{result.stuck_cleaned}")
    Logger.info("Old jobs deleted: #{result.old_deleted}")
    
  {:error, reason} ->
    Logger.error("Cleanup failed", reason: reason)
end

Logger.info("Script completed")