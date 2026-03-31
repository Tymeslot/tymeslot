defmodule Tymeslot.Workers.DeadChannelAlertWorker do
  @moduledoc """
  Oban worker that detects calendar integrations with silent webhook channels.

  An integration is flagged when ALL of the following are true:
  - The integration is active
  - The channel/subscription has not expired
  - No notification has been received in the past 12 hours (or ever)
  - At least one confirmed meeting linked to this integration exists within the past 72 hours

  Runs every 6 hours. Emits a structured log warning for each flagged integration.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 1

  require Logger

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries

  @silence_threshold_hours 12
  @meeting_lookback_hours 72

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@silence_threshold_hours * 3600)
    meeting_since = DateTime.add(DateTime.utc_now(), -@meeting_lookback_hours * 3600)

    dead_google = CalendarIntegrationQueries.list_silent_google_channels(cutoff, meeting_since)

    dead_outlook =
      CalendarIntegrationQueries.list_silent_outlook_subscriptions(cutoff, meeting_since)

    Enum.each(dead_google ++ dead_outlook, fn integration ->
      Logger.warning("Calendar integration silent — possible dead channel",
        calendar_integration_id: integration.id,
        provider: integration.provider,
        user_id: integration.user_id,
        last_notification_at: inspect(notification_timestamp(integration))
      )
    end)

    count = length(dead_google) + length(dead_outlook)

    Logger.info("DeadChannelAlertWorker complete",
      flagged_google: length(dead_google),
      flagged_outlook: length(dead_outlook),
      total_flagged: count
    )

    :ok
  end

  defp notification_timestamp(%{provider: "google"} = i), do: i.last_google_notification_at
  defp notification_timestamp(%{provider: "outlook"} = i), do: i.last_outlook_notification_at
  defp notification_timestamp(_integration), do: nil
end
