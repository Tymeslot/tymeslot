defmodule Tymeslot.Workers.WorkerBackoffSchedulesTest do
  # Each worker's retry schedule was chosen for its provider's quotas. The
  # arithmetic is shared through `Tymeslot.Workers.Backoff`; these literals
  # pin the numbers, so a change to the shared module cannot shift them.
  use ExUnit.Case, async: true

  @moduletag :workers
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.EmailWorker.AdminAlertScheduler
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.VideoIntegrationDisconnectWorker
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.Workers.WebhookWorker

  @schedules [
    {CalendarEventWorker, %{}, [30, 60, 120, 180]},
    {RefreshOutlookCalendarWorker, %{}, [30, 90, 240, 480, 480]},
    {VideoIntegrationDisconnectWorker, %{}, [30, 60, 120, 180, 180]},
    {VideoSyncWorker, %{}, [30, 60, 120, 180, 180]},
    {WebhookWorker, %{}, [30, 120, 600, 1_800, 3_600, 10_800, 21_600, 21_600]},
    {EmailWorker, %{"action" => "send_confirmation"}, [1, 2, 4, 8, 16, 32, 64, 120, 120]},
    {EmailWorker, %{"action" => "send_admin_alert"},
     [60, 120, 240, 480, 960, 1_920, 3_600, 3_600]},
    {AdminAlertScheduler, %{}, [60, 120, 240, 480, 960, 1_920, 3_600, 3_600]},
    {RefundLatePayment, %{}, [60, 120, 240, 480, 960, 1_920, 3_600, 3_600]},
    {TokenRefreshJob, %{}, [1, 3, 10, 300, 900, 1_800, 3_600, 3_600]}
  ]

  for {worker, args, expected} <- @schedules do
    test "#{inspect(worker)} keeps its backoff schedule for #{inspect(args)}" do
      worker = unquote(worker)
      args = unquote(Macro.escape(args))
      expected = unquote(expected)

      actual =
        for attempt <- 1..length(expected),
            do: worker.backoff(%Oban.Job{attempt: attempt, args: args})

      assert actual == expected
    end
  end
end
