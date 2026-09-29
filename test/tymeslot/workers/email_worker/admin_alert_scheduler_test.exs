defmodule Tymeslot.Workers.EmailWorker.AdminAlertSchedulerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Ecto.Changeset
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.EmailWorker.AdminAlertScheduler

  describe "schedule/5 success path" do
    test "returns :ok and enqueues an EmailWorker job with expected args" do
      assert :ok =
               AdminAlertScheduler.schedule(
                 "ops@example.com",
                 "Webhook",
                 :warning,
                 "Test alert",
                 %{"event_id" => "evt_001"}
               )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_admin_alert",
          "recipient" => "ops@example.com",
          "category" => "Webhook",
          "severity" => "warning",
          "message" => "Test alert"
        }
      )
    end

    test "serialises severity atom to string in job args" do
      assert :ok =
               AdminAlertScheduler.schedule(
                 "ops@example.com",
                 "General",
                 :error,
                 "Error alert",
                 %{}
               )

      [job] = all_enqueued(worker: EmailWorker)
      assert job.args["severity"] == "error"
    end

    test "includes alert_hash derived from category and message" do
      assert :ok =
               AdminAlertScheduler.schedule(
                 "ops@example.com",
                 "Payments",
                 :info,
                 "Refund processed",
                 %{}
               )

      [job] = all_enqueued(worker: EmailWorker)
      assert String.length(job.args["alert_hash"]) == 64
    end

    test "same category+message produces the same alert_hash" do
      args1 = AdminAlertScheduler.build_args("a@a.com", "Cat", :warning, "Msg", %{})
      args2 = AdminAlertScheduler.build_args("b@b.com", "Cat", :error, "Msg", %{})

      assert args1["alert_hash"] == args2["alert_hash"]
    end

    test "different message produces a different alert_hash" do
      args1 = AdminAlertScheduler.build_args("ops@example.com", "Cat", :warning, "Msg A", %{})
      args2 = AdminAlertScheduler.build_args("ops@example.com", "Cat", :warning, "Msg B", %{})

      refute args1["alert_hash"] == args2["alert_hash"]
    end

    test "an explicit dedup_key overrides the message in the alert_hash" do
      args1 =
        AdminAlertScheduler.build_args("ops@example.com", "Cat", :warning, "Job 1 failed", %{},
          dedup_key: "worker:queue"
        )

      args2 =
        AdminAlertScheduler.build_args("ops@example.com", "Cat", :warning, "Job 2 failed", %{},
          dedup_key: "worker:queue"
        )

      assert args1["alert_hash"] == args2["alert_hash"]
    end

    test "duplicate alerts sharing a dedup_key enqueue only one job despite different messages" do
      assert :ok =
               AdminAlertScheduler.schedule(
                 "ops@example.com",
                 "Queue",
                 :error,
                 "Oban job MyWorker (queue: q) failed permanently: error for job 1",
                 %{},
                 dedup_key: "new_error:41"
               )

      assert :ok =
               AdminAlertScheduler.schedule(
                 "ops@example.com",
                 "Queue",
                 :error,
                 "Oban job MyWorker (queue: q) failed permanently: error for job 2",
                 %{},
                 dedup_key: "new_error:41"
               )

      assert [_only_one] = all_enqueued(worker: EmailWorker)
    end

    test "a deduplicated alert logs at debug, not as a fresh send" do
      # Oban answers a uniqueness conflict with `{:ok, job}` carrying
      # `conflict?: true`, not an insert error. Treating that as a successful
      # schedule made a worker failing on a loop look like it was emailing an
      # operator every cycle when the dedup window was suppressing all but one.
      # The suite runs at :warning, which filters debug before any capture
      # handler sees it; a module-scoped override lifts it for this module only.
      Logger.put_module_level(AdminAlertScheduler, :debug)
      on_exit(fn -> Logger.delete_module_level(AdminAlertScheduler) end)

      assert :ok =
               AdminAlertScheduler.schedule(
                 "ops@example.com",
                 "Queue",
                 :error,
                 "Repeat alert",
                 %{},
                 dedup_key: "new_error:41"
               )

      log =
        capture_log([level: :debug], fn ->
          assert :ok =
                   AdminAlertScheduler.schedule(
                     "ops@example.com",
                     "Queue",
                     :error,
                     "Repeat alert",
                     %{},
                     dedup_key: "new_error:41"
                   )
        end)

      assert log =~ "deduplicated"
      refute log =~ "Admin alert email scheduled"
    end

    # Oban's default unique states stop at :completed, so an alert job that
    # exhausted its retries used to release the dedup slot the instant it
    # discarded — and a discard is itself what raises the next alert, so an
    # email outage produced an unbounded chain rather than one deduplicated job.
    test "a discarded alert keeps holding the dedup slot" do
      assert :ok =
               AdminAlertScheduler.schedule(
                 "ops@example.com",
                 "Queue",
                 :error,
                 "Oban job EmailWorker (queue: emails) failed permanently",
                 %{},
                 dedup_key: "new_error:42"
               )

      [job] = all_enqueued(worker: EmailWorker)
      job |> Changeset.change(state: "discarded") |> Repo.update!()

      assert :ok =
               AdminAlertScheduler.schedule(
                 "ops@example.com",
                 "Queue",
                 :error,
                 "Oban job EmailWorker (queue: emails) failed permanently, again",
                 %{},
                 dedup_key: "new_error:42"
               )

      assert Repo.aggregate(Oban.Job, :count) == 1
    end
  end

  describe "retry policy" do
    # An alert is most needed during the outage that stops it being delivered.
    # The default EmailWorker policy spends its five attempts in about half a
    # minute, and a discarded alert keeps holding the 24-hour dedup slot, so
    # an SMTP outage of any length lost the alert and every repeat of it.
    test "an admin alert job retries for at least 12 hours, one capped step at a time" do
      assert :ok =
               AdminAlertScheduler.schedule("ops@example.com", "Queue", :error, "Outage", %{})

      [job] = all_enqueued(worker: EmailWorker)
      assert job.max_attempts == 20

      backoffs = Enum.map(1..(job.max_attempts - 1), &EmailWorker.backoff(%{job | attempt: &1}))

      assert Enum.sum(backoffs) >= 12 * 3_600
      assert Enum.max(backoffs) <= 2 * 3_600
    end

    # The whole retry span sits inside the dedup window, so a repeat of the
    # alert raised while the job is still retrying never slips past the slot.
    test "an admin alert job's whole retry span fits inside the dedup window" do
      assert :ok =
               AdminAlertScheduler.schedule("ops@example.com", "Queue", :error, "Outage", %{})

      [job] = all_enqueued(worker: EmailWorker)
      backoffs = Enum.map(1..(job.max_attempts - 1), &EmailWorker.backoff(%{job | attempt: &1}))

      assert Enum.sum(backoffs) < 86_400
    end

    test "other email jobs keep five attempts and the seconds-scale backoff" do
      job = %Oban.Job{args: %{"action" => "send_confirmation_emails", "meeting_id" => 1}}

      changeset = EmailWorker.new(job.args)
      assert Changeset.get_field(changeset, :max_attempts) == 5

      assert Enum.map(1..6, &EmailWorker.backoff(%{job | attempt: &1})) ==
               [1, 2, 4, 8, 16, 16]
    end

    test "a repeat of an alert that is still retrying is deduplicated" do
      assert :ok =
               AdminAlertScheduler.schedule("ops@example.com", "Queue", :error, "Outage", %{})

      [job] = all_enqueued(worker: EmailWorker)
      job |> Changeset.change(state: "retryable", attempt: 3) |> Repo.update!()

      assert :ok =
               AdminAlertScheduler.schedule("ops@example.com", "Queue", :error, "Outage", %{})

      assert [%Oban.Job{id: id, state: "retryable"}] = Repo.all(Oban.Job)
      assert id == job.id
    end
  end

  describe "build_args/5" do
    test "serialises atom metadata values to strings" do
      args =
        AdminAlertScheduler.build_args("ops@example.com", "Cat", :warning, "Msg", %{env: :prod})

      assert args["metadata"]["env"] == "prod"
    end

    test "preserves numeric metadata values" do
      args =
        AdminAlertScheduler.build_args("ops@example.com", "Cat", :warning, "Msg", %{count: 42})

      assert args["metadata"]["count"] == 42
    end

    test "converts atom metadata keys to strings" do
      args =
        AdminAlertScheduler.build_args("ops@example.com", "Cat", :warning, "Msg", %{
          my_key: "value"
        })

      assert Map.has_key?(args["metadata"], "my_key")
    end
  end
end
