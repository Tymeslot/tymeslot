defmodule Tymeslot.Workers.EmailWorker.AdminAlertSchedulerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :unit

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
      assert is_binary(job.args["alert_hash"])
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

    test "crash alerts with same reason_code and top stacktrace frame produce the same hash regardless of message" do
      stacktrace =
        "    (myapp 1.0.0) lib/myapp/worker.ex:42: MyApp.Worker.run/1\n    (oban 2.0.0) lib/oban/queue/executor.ex:10: Oban.Queue.Executor.call/2"

      args1 =
        AdminAlertScheduler.build_args(
          "ops@example.com",
          "System",
          :error,
          "Unhandled error crash: could not process user_id=1",
          %{reason_code: Postgrex.Error, kind: :error, stacktrace: stacktrace}
        )

      args2 =
        AdminAlertScheduler.build_args(
          "ops@example.com",
          "System",
          :error,
          "Unhandled error crash: could not process user_id=9999",
          %{reason_code: Postgrex.Error, kind: :error, stacktrace: stacktrace}
        )

      assert args1["alert_hash"] == args2["alert_hash"]
    end

    test "crash alerts with different reason_code produce different hashes" do
      stacktrace = "    (myapp 1.0.0) lib/myapp/worker.ex:42: MyApp.Worker.run/1"

      args1 =
        AdminAlertScheduler.build_args(
          "ops@example.com",
          "System",
          :error,
          "Unhandled error crash: boom",
          %{reason_code: KeyError, kind: :error, stacktrace: stacktrace}
        )

      args2 =
        AdminAlertScheduler.build_args(
          "ops@example.com",
          "System",
          :error,
          "Unhandled error crash: boom",
          %{reason_code: ArgumentError, kind: :error, stacktrace: stacktrace}
        )

      refute args1["alert_hash"] == args2["alert_hash"]
    end

    test "crash alerts with different top stacktrace frame produce different hashes" do
      args1 =
        AdminAlertScheduler.build_args(
          "ops@example.com",
          "System",
          :error,
          "Unhandled error crash: boom",
          %{
            reason_code: RuntimeError,
            kind: :error,
            stacktrace: "    lib/myapp/foo.ex:10: Foo.bar/1"
          }
        )

      args2 =
        AdminAlertScheduler.build_args(
          "ops@example.com",
          "System",
          :error,
          "Unhandled error crash: boom",
          %{
            reason_code: RuntimeError,
            kind: :error,
            stacktrace: "    lib/myapp/baz.ex:99: Baz.qux/2"
          }
        )

      refute args1["alert_hash"] == args2["alert_hash"]
    end

    test "alerts without reason_code or stacktrace fall back to category+message hash" do
      args1 =
        AdminAlertScheduler.build_args("ops@example.com", "Queue", :warning, "Queue stuck", %{
          affected_queues: ["default"]
        })

      args2 =
        AdminAlertScheduler.build_args("ops@example.com", "Queue", :warning, "Queue stuck", %{
          affected_queues: ["mailer"]
        })

      assert args1["alert_hash"] == args2["alert_hash"]
    end

    test "alerts with only reason_code but no stacktrace fall back to category+message hash" do
      args1 =
        AdminAlertScheduler.build_args(
          "ops@example.com",
          "System",
          :error,
          "Unhandled error crash: msg A",
          %{reason_code: RuntimeError}
        )

      args2 =
        AdminAlertScheduler.build_args(
          "ops@example.com",
          "System",
          :error,
          "Unhandled error crash: msg B",
          %{reason_code: RuntimeError}
        )

      refute args1["alert_hash"] == args2["alert_hash"]
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
