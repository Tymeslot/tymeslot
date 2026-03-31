defmodule Tymeslot.Workers.ReregisterOutlookSubscriptionWorker do
  @moduledoc """
  Oban worker that re-registers a Microsoft Graph subscription for an
  Outlook Calendar integration.

  Enqueued by the lifecycle controller when Graph sends a
  `reauthorizationRequired` or `subscriptionRemoved` event. Using an Oban
  job instead of a raw Task.Supervisor spawn gives us:

  - **Deduplication**: `unique` prevents multiple concurrent re-registrations
    for the same integration (e.g., when Graph sends a batch of lifecycle
    events for the same subscription).
  - **Retries**: Oban retries on transient failures with backoff.
  - **Observability**: Jobs are visible in the Oban dashboard.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    unique: [period: 120, keys: [:calendar_integration_id]]

  require Logger

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id}}) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        case OutlookCalendarAPI.register_graph_subscription(integration) do
          {:ok, _updated} ->
            Logger.info("Outlook Graph subscription re-registered",
              integration_id: integration.id
            )

            :ok

          {:error, reason} ->
            Logger.error("Outlook Graph subscription re-registration failed",
              integration_id: integration.id,
              reason: inspect(reason)
            )

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("Integration not found for Graph subscription re-registration",
          calendar_integration_id: integration_id
        )

        {:discard, "Integration not found"}
    end
  end
end
