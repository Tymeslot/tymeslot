defmodule Tymeslot.Workers.AccountDeletionSweepWorker do
  @moduledoc """
  Daily safety net for account deletions: queues a deletion job for every
  overdue account, in case its own job was lost (a database restored from
  backup, say) or discarded after its retries ran out.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]

  require Logger

  alias Tymeslot.Auth

  @impl Oban.Worker
  def perform(_job) do
    case Auth.enqueue_overdue_account_deletions() do
      0 -> :ok
      count -> Logger.info("Queued overdue account deletions", count: count)
    end

    :ok
  end
end
