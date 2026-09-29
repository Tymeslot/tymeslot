defmodule Tymeslot.Infrastructure.AdminAlerts.ErrorBurstTest do
  # A burst of new-error alerts sends the first few emails and one roll-up,
  # not one email per error.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :emails

  import Ecto.Query
  import Mox
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias Tymeslot.Emails.EmailService
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.DigestEntrySchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AdminAlertDigestWorker
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.EmailNotifier,
      admin_alerts_enabled: true,
      admin_alert_email: "ops@example.com",
      error_alert_burst: [immediate_per_window: 3, window_seconds: 3_600, listed: 10]
    )
  end

  defp new_error(error_id) do
    AdminAlerts.send_alert(:new_error, %{
      summary: "New error",
      error_id: error_id,
      occurrence_id: error_id * 100,
      kind: "Elixir.RuntimeError",
      source_function: "Example.run_#{error_id}/0",
      reason_message: "boom #{error_id}"
    })
  end

  defp regression(error_id, occurrence_id) do
    AdminAlerts.send_alert(:error_regression, %{
      summary: "Resolved error happened again",
      error_id: error_id,
      occurrence_id: occurrence_id,
      kind: "Elixir.RuntimeError",
      source_function: "Example.run_#{error_id}/0",
      reason_message: "boom #{error_id}"
    })
  end

  defp alert_jobs, do: jobs_with_action("send_admin_alert")
  defp roll_up_email_jobs, do: jobs_with_action("send_admin_alert_digest")

  defp jobs_with_action(action),
    do: Enum.filter(all_enqueued(worker: EmailWorker), &(&1.args["action"] == action))

  defp roll_up_jobs,
    do: all_enqueued(worker: AdminAlertDigestWorker, args: %{"batch" => "errors"})

  # Runs the scheduled roll-up and returns the one email job it hands off.
  defp run_roll_up! do
    assert [job] = roll_up_jobs()
    assert :ok = perform_job(AdminAlertDigestWorker, job.args)
    assert [email_job] = roll_up_email_jobs()
    email_job
  end

  describe "under the cap" do
    test "each error alert is emailed at once and nothing waits for a roll-up" do
      for error_id <- 1..3, do: assert(:ok = new_error(error_id))

      assert length(alert_jobs()) == 3
      assert Repo.all(DigestEntrySchema) == []
      assert roll_up_jobs() == []
    end

    test "alerts emailed longer ago than the window no longer count against it" do
      for error_id <- 1..3, do: new_error(error_id)

      Repo.update_all(Oban.Job,
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3_601, :second)]
      )

      assert :ok = new_error(4)

      assert length(alert_jobs()) == 4
      assert Repo.all(DigestEntrySchema) == []
    end
  end

  describe "over the cap" do
    test "holds every further alert and schedules exactly one roll-up for the end of the window" do
      for error_id <- 1..15, do: assert(:ok = new_error(error_id))

      assert length(alert_jobs()) == 3

      entries = Repo.all(DigestEntrySchema)
      assert length(entries) == 12
      assert Enum.all?(entries, &(&1.batch == "errors"))

      assert [roll_up] = roll_up_jobs()

      oldest_alert = alert_jobs() |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime)

      assert_in_delta DateTime.diff(roll_up.scheduled_at, oldest_alert), 3_600, 5
    end

    test "the roll-up lists the newest ten, newest first, and counts the rest" do
      for error_id <- 1..15, do: new_error(error_id)

      email_job = run_roll_up!()

      assert email_job.args["kind"] == "errors"
      assert email_job.max_attempts == 20

      listed_ids = Enum.map(email_job.args["entries"], & &1["metadata"]["error_id"])
      assert listed_ids == Enum.to_list(15..6//-1)
      assert email_job.args["omitted"] == %{"new_error" => 2}
      assert Repo.all(DigestEntrySchema) == []
    end

    test "the roll-up email names the held-back errors and how many more there were" do
      Application.put_env(:swoosh, :shared_test_process, self())
      on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
      stub(EmailServiceMock, :send_admin_alert_digest, &EmailService.send_admin_alert_digest/2)

      for error_id <- 1..15, do: new_error(error_id)
      email_job = run_roll_up!()

      assert :ok = perform_job(EmailWorker, email_job.args)

      assert_received {:email, email}
      assert email.to == [{"Tymeslot Operator", "ops@example.com"}]
      assert email.subject == "[ERROR] Tymeslot: 12 more error alerts this hour"
      assert email.text_body =~ "RuntimeError in Example.run_15/0: boom 15"
      refute email.text_body =~ "Example.run_5/0"
      assert email.text_body =~ "new_error: 2 alerts"
    end

    test "each listed error carries its stored occurrence count" do
      error = insert_error_with_occurrences(4)

      # Ids no stored error has, to fill the window.
      for error_id <- 1_000_001..1_000_003, do: new_error(error_id)
      new_error(error.id)

      email_job = run_roll_up!()

      assert [%{"error_occurrences" => 4}] = email_job.args["entries"]
    end

    test "a regression of an error already held collapses into its entry" do
      for error_id <- 1..4, do: new_error(error_id)
      regression(4, 401)

      assert [entry] = Repo.all(DigestEntrySchema)
      assert entry.occurrences == 2
      assert length(roll_up_jobs()) == 1
    end

    test "nothing is lost while the mail server is down: the roll-up retries with every entry" do
      expect(EmailServiceMock, :send_admin_alert_digest, fn _recipient, _digest ->
        {:error, "SMTP unavailable"}
      end)

      for error_id <- 1..5, do: new_error(error_id)
      email_job = run_roll_up!()

      assert {:error, _reason} = perform_job(EmailWorker, email_job.args)

      assert Enum.map(email_job.args["entries"], & &1["metadata"]["error_id"]) == [5, 4]
      assert EmailWorker.backoff(%{email_job | attempt: 3}) == 240
    end

    test "with alerts switched off by the time it runs, the roll-up drops what waited" do
      for error_id <- 1..5, do: new_error(error_id)
      [job] = roll_up_jobs()
      with_config(:tymeslot, admin_alerts_enabled: false)

      assert :ok = perform_job(AdminAlertDigestWorker, job.args)

      assert roll_up_email_jobs() == []
      assert Repo.all(DigestEntrySchema) == []
    end
  end

  test "the daily digest leaves held error alerts for their roll-up" do
    for error_id <- 1..4, do: new_error(error_id)

    assert :ok = perform_job(AdminAlertDigestWorker, %{})

    assert roll_up_email_jobs() == []
    assert [%{batch: "errors"}] = Repo.all(DigestEntrySchema)
  end

  defp insert_error_with_occurrences(count) do
    error =
      Repo.insert!(%Error{
        kind: "Elixir.RuntimeError",
        reason: "boom",
        source_line: "lib/example.ex:#{System.unique_integer([:positive])}",
        source_function: "Example.run/0",
        fingerprint: Base.encode16(:crypto.strong_rand_bytes(16)),
        status: :unresolved,
        muted: false,
        last_occurrence_at: DateTime.utc_now()
      })

    for _n <- 1..count do
      Repo.insert!(%Occurrence{
        error_id: error.id,
        reason: "boom",
        context: %{},
        breadcrumbs: [],
        stacktrace: %ErrorTracker.Stacktrace{lines: []}
      })
    end

    assert Repo.aggregate(from(o in Occurrence, where: o.error_id == ^error.id), :count) == count
    error
  end
end
