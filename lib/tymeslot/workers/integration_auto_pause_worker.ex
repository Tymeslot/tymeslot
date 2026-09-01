defmodule Tymeslot.Workers.IntegrationAutoPauseWorker do
  @moduledoc """
  Daily Oban cron job that pauses integrations whose health state has been
  unhealthy long enough that continuing to probe them is wasted work.
  Pausing sets `is_active: false` on the integration so the scheduled probe
  loop stops enqueueing work for it, and sends a one-off "paused"
  notification email.

  ## Triggers (dual threshold)

  Either of the following marks an integration as pausable:

    * **Sustained hard failures** — `consecutive_hard_failures >=
      :auto_pause_hard_failure_count` (default 168 ≈ ~7 days at the 1-hour
      unhealthy probe cadence). Catches the "token revoked, server gone"
      case quickly. The counter only ticks on hard failures and is reset by
      *any* success, so this cleanly excludes flappy integrations.

    * **Prolonged unhealthy streak** — `became_unhealthy_at <
      now - :auto_pause_cutoff_days` (default 14 days). Catches the
      ambiguous slow-decay case where probes occasionally succeed but the
      integration never reaches the 2-success healthy threshold. The
      `became_unhealthy_at` timestamp is reset by full recovery, by any
      successful sync (`HealthCheck.mark_synced_successfully/2`), and by
      user actions (`HealthCheck.mark_user_recovered/2`), so a real recovery
      anywhere inside the 14 days clears the timer.

  Both triggers also require the *current* status to be `"unhealthy"`, so an
  integration that's working today but was broken in the past is never
  paused.

  ## Why pause and not delete

  We never delete an integration on the user's behalf. Pausing preserves the
  user's settings, calendar selections, and history; reactivating restores
  the integration and resets the health monitor.

  ## Idempotency

  The pause query filters by `s.status == "unhealthy"`, so an already-paused
  integration won't be picked up again on the next run (its row is unchanged
  because the probe loop skips inactive integrations and never updates the
  status). The "paused" email scheduler also has a 90-day uniqueness window
  as a belt-and-suspenders defence against duplicates.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 3,
    priority: 3

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.HealthStatus
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  @default_cutoff_days 14
  @default_hard_failure_count 168
  @unhealthy_status HealthStatus.to_db_value(:unhealthy)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff_days = cutoff_days()
    hard_failure_count = hard_failure_count()
    calendar_cutoff = DateTime.add(DateTime.utc_now(), -cutoff_days * 24 * 3600, :second)

    paused_calendar = pause_type(:calendar, calendar_cutoff, hard_failure_count, cutoff_days)
    paused_video = pause_type(:video, calendar_cutoff, hard_failure_count, cutoff_days)

    Logger.info("IntegrationAutoPauseWorker pass complete",
      cutoff_days: cutoff_days,
      hard_failure_count: hard_failure_count,
      paused_calendar: paused_calendar,
      paused_video: paused_video
    )

    :ok
  end

  defp pause_type(type, calendar_cutoff, hard_failure_count, cutoff_days) do
    rows =
      IntegrationHealthStateQueries.list_pausable(type, calendar_cutoff, hard_failure_count)

    Enum.count(rows, fn row ->
      pause_one(type, row, calendar_cutoff, hard_failure_count, cutoff_days) == :ok
    end)
  end

  defp pause_one(type, row, calendar_cutoff, hard_failure_count, cutoff_days) do
    case fetch_active_integration(type, row.integration_id) do
      {:ok, integration} ->
        # Re-read the health state immediately before deactivating to guard
        # against the race where a concurrent sync worker reset the row to
        # "healthy" after list_pausable returned the stale unhealthy snapshot.
        case IntegrationHealthStateQueries.get(type, row.integration_id) do
          {:ok, %{status: @unhealthy_status} = fresh_row} ->
            case deactivate(type, integration) do
              {:ok, paused} ->
                Logger.info("Auto-pausing integration",
                  type: type,
                  integration_id: row.integration_id,
                  trigger: pause_trigger(fresh_row, calendar_cutoff, hard_failure_count),
                  consecutive_hard_failures: fresh_row.consecutive_hard_failures,
                  became_unhealthy_at: fresh_row.became_unhealthy_at
                )

                schedule_email(type, paused, row.user_id, cutoff_days)
                :ok

              {:error, changeset} ->
                Logger.error("Failed to auto-pause integration",
                  type: type,
                  integration_id: row.integration_id,
                  error: inspect(changeset)
                )

                :error
            end

          {:ok, _recovered} ->
            Logger.info("Skipping auto-pause — integration recovered since list_pausable ran",
              type: type,
              integration_id: row.integration_id
            )

            :skip

          {:error, :not_found} ->
            :skip
        end

      :skip ->
        :skip
    end
  end

  @spec pause_trigger(IntegrationHealthStateSchema.t(), DateTime.t(), non_neg_integer()) ::
          :sustained_hard_failures | :prolonged_unhealthy | :both
  defp pause_trigger(row, calendar_cutoff, hard_failure_count) do
    hard? = row.consecutive_hard_failures >= hard_failure_count

    prolonged? =
      not is_nil(row.became_unhealthy_at) and
        DateTime.compare(row.became_unhealthy_at, calendar_cutoff) == :lt

    case {hard?, prolonged?} do
      {true, true} -> :both
      {true, false} -> :sustained_hard_failures
      {false, true} -> :prolonged_unhealthy
      # Should never reach here — the query guarantees at least one is true.
      {false, false} -> :prolonged_unhealthy
    end
  end

  defp fetch_active_integration(:calendar, integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, %{is_active: true} = integration} ->
        {:ok, integration}

      {:ok, _inactive} ->
        :skip

      {:error, :not_found} ->
        :skip

      {:error, :requires_reencryption, _stale} ->
        # The decryption-failure path already flags reauth; we don't need to
        # also deactivate. Skip so a later sweep can pick it up if it stays
        # unhealthy.
        :skip
    end
  end

  defp fetch_active_integration(:video, integration_id) do
    case VideoIntegrationQueries.get(integration_id) do
      {:ok, %{is_active: true} = integration} ->
        {:ok, integration}

      {:ok, _inactive} ->
        :skip

      {:error, :not_found} ->
        :skip

      {:error, :requires_reencryption, _stale} ->
        :skip
    end
  end

  defp deactivate(:calendar, integration) do
    CalendarIntegrationQueries.toggle_active(integration)
  end

  defp deactivate(:video, integration) do
    VideoIntegrationQueries.toggle_active(integration)
  end

  defp schedule_email(type, integration, user_id, cutoff_days) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        EmailScheduler.schedule_integration_paused_notification(
          user,
          integration,
          type,
          cutoff_days
        )

      {:error, _reason} ->
        Logger.warning("User not found for paused notification",
          integration_id: integration.id,
          user_id: user_id
        )

        :ok
    end
  end

  defp cutoff_days do
    Application.get_env(:tymeslot, :auto_pause_cutoff_days, @default_cutoff_days)
  end

  defp hard_failure_count do
    Application.get_env(:tymeslot, :auto_pause_hard_failure_count, @default_hard_failure_count)
  end
end
