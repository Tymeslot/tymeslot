defmodule Tymeslot.Workers.AccountDeletionWorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :auth

  import Ecto.Query
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Oban.Job
  alias Tymeslot.Auth
  alias Tymeslot.Auth.AccountDeletion.Runner
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.{AccountDeletionSweepWorker, AccountDeletionWorker}

  defmodule RefusingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(_user_id, _feedback), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: {:error, :billing_unreachable}
  end

  setup do
    with_config(:tymeslot, :account_deletion_hook, nil)
    :ok
  end

  test "deletes a due account" do
    at = DateTime.add(DateTime.utc_now(:second), -1, :second)
    user = insert(:user, deletion_requested_at: at, deletion_scheduled_at: at)

    assert perform_job(AccountDeletionWorker, %{"user_id" => user.id}) == :ok
    refute Repo.get(UserSchema, user.id)
  end

  test "snoozes until the account is due" do
    at = DateTime.add(DateTime.utc_now(:second), 1, :day)
    user = insert(:user, deletion_requested_at: at, deletion_scheduled_at: at)

    assert {:snooze, _seconds} = perform_job(AccountDeletionWorker, %{"user_id" => user.id})
  end

  test "is unique per user while a job is waiting" do
    at = DateTime.add(DateTime.utc_now(:second), 1, :day)

    assert {:ok, %Job{conflict?: false}} = AccountDeletionWorker.schedule(42, at)
    assert {:ok, %Job{conflict?: true}} = AccountDeletionWorker.schedule(42, at)
  end

  test "the daily sweep queues the overdue accounts" do
    at = DateTime.add(DateTime.utc_now(:second), -1, :day)
    user = insert(:user, deletion_requested_at: at, deletion_scheduled_at: at)

    assert perform_job(AccountDeletionSweepWorker, %{}) == :ok
    assert_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => user.id})
  end

  describe "a deletion the hook keeps refusing" do
    setup :capture_admin_alerts

    setup do
      with_config(:tymeslot, :account_deletion_hook, RefusingHook)
      at = DateTime.add(DateTime.utc_now(:second), -1, :second)
      %{user: insert(:user, deletion_requested_at: at, deletion_scheduled_at: at)}
    end

    test "retries without an alert before the last attempt", %{user: user} do
      assert perform_job(AccountDeletionWorker, %{"user_id" => user.id},
               attempt: 4,
               max_attempts: 5
             ) == {:error, :billing_unreachable}

      refute_received {:send_alert, _type, _payload}
      assert Repo.get(UserSchema, user.id)
    end

    test "raises an admin alert on the last attempt", %{user: user} do
      assert perform_job(AccountDeletionWorker, %{"user_id" => user.id},
               attempt: 5,
               max_attempts: 5
             ) == {:error, :billing_unreachable}

      assert_received {:send_alert, :account_deletion_stalled, payload}
      assert payload.user_id == user.id
      assert payload.reason_message =~ "billing_unreachable"
      assert Repo.get(UserSchema, user.id)
    end
  end

  describe "the sweep and existing jobs" do
    defp overdue_user do
      at = DateTime.add(DateTime.utc_now(:second), -1, :day)
      insert(:user, deletion_requested_at: at, deletion_scheduled_at: at)
    end

    test "queues a new job for an account whose job was discarded" do
      user = overdue_user()
      {:ok, job} = AccountDeletionWorker.schedule(user.id, DateTime.utc_now())
      job |> Changeset.change(state: "discarded") |> Repo.update!()

      assert Auth.enqueue_overdue_account_deletions() == 1
      assert [_discarded, _new] = all_jobs(user.id)
    end

    test "does not re-queue an account that has a live job" do
      user = overdue_user()
      {:ok, _job} = AccountDeletionWorker.schedule(user.id, DateTime.utc_now())

      assert Auth.enqueue_overdue_account_deletions() == 0
      assert [_only] = all_jobs(user.id)
    end

    test "accounts with a live job do not use up the sweep's batch" do
      with_job = overdue_user()
      {:ok, _job} = AccountDeletionWorker.schedule(with_job.id, DateTime.utc_now())
      without_job = overdue_user()

      assert Runner.enqueue_overdue(DateTime.utc_now(), 1) == 1
      assert [_new] = all_jobs(without_job.id)
    end

    defp all_jobs(user_id) do
      Repo.all(
        from(j in Job,
          where: j.worker == "Tymeslot.Workers.AccountDeletionWorker",
          where: fragment("?->>'user_id' = ?", j.args, ^to_string(user_id))
        )
      )
    end
  end
end
