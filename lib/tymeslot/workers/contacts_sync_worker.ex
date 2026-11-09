defmodule Tymeslot.Workers.ContactsSyncWorker do
  @moduledoc """
  Syncs one calendar connection's address books into Tymeslot
  (`Tymeslot.Contacts.Sync`), when its owner turns contact suggestions on
  and on every `Tymeslot.Workers.ContactsSyncSweepWorker` sweep after that.

  A connection that no longer suggests contacts by the time the job runs
  has what was synced deleted instead, and one that cannot be read is left
  as it was until the next sweep: its calendar sync is what tells the owner
  to reconnect.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 3,
    unique: [
      fields: [:worker, :args],
      # Below the sweep's 15 minutes, so a sweep is never swallowed by the
      # one before it.
      period: 600,
      states: [:available, :scheduled, :retryable]
    ]

  require Logger

  alias Tymeslot.Contacts
  alias Tymeslot.Contacts.Sync
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries

  @doc "The job syncing the connection `integration_id`."
  @spec job(pos_integer(), keyword()) :: Oban.Job.changeset()
  def job(integration_id, opts \\ []),
    do: new(%{"calendar_integration_id" => integration_id}, opts)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id}})
      when is_integer(integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} -> sync(integration)
      {:error, :not_found} -> {:discard, "Calendar integration not found"}
      {:error, :requires_reencryption, _integration} -> {:discard, "Credentials unreadable"}
    end
  end

  def perform(_job), do: {:discard, "Invalid arguments"}

  defp sync(%{use_for_contacts: true, is_active: true} = integration) do
    if Contacts.supported_provider?(integration.provider) do
      run(integration)
    else
      Contacts.drop(integration.id)
    end
  end

  defp sync(integration), do: Contacts.drop(integration.id)

  defp run(integration) do
    case Sync.run(integration) do
      {:ok, outcome} ->
        Logger.debug("Contacts synced", integration_id: integration.id, outcome: inspect(outcome))
        :ok

      {:error, reason} ->
        Logger.info("Address books could not be read",
          integration_id: integration.id,
          reason: LogFormat.reason(reason)
        )

        # Retrying re-sends what the server just refused; the next sweep
        # tries again in 15 minutes.
        :ok
    end
  end
end
