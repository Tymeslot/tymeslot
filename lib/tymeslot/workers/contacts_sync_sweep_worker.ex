defmodule Tymeslot.Workers.ContactsSyncSweepWorker do
  @moduledoc """
  Every 15 minutes, queues a `Tymeslot.Workers.ContactsSyncWorker` job for
  each calendar connection that suggests contacts, a second apart so the
  servers and the queue are not asked all at once, and deletes what is left
  synced for connections that stopped suggesting them while a sync was
  still writing.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 1,
    unique: [period: 840]

  require Logger

  alias Tymeslot.Contacts
  alias Tymeslot.Contacts.ContactQueries
  alias Tymeslot.Workers.ContactsSyncWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    dropped = ContactQueries.delete_for_inactive()
    ids = ContactQueries.integration_ids_taking_part(Contacts.supported_providers())

    ids
    |> Enum.with_index()
    |> Enum.each(fn {id, index} ->
      Oban.insert(ContactsSyncWorker.job(id, schedule_in: index))
    end)

    Logger.info("Contacts sync sweep queued", connections: length(ids), dropped_books: dropped)
    :ok
  end
end
