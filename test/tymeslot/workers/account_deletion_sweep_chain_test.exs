defmodule Tymeslot.Workers.AccountDeletionSweepChainTest do
  @moduledoc """
  The daily account deletion sweep end to end: the sweep queues an
  `AccountDeletionWorker` job for each account past its scheduled deletion,
  the job deletes it, and an account whose grace period is still running is
  left alone. The sweep's queueing alone is covered in
  `AccountDeletionWorkerTest`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :auth

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.{AccountDeletionSweepWorker, AccountDeletionWorker}

  setup do
    with_config(:tymeslot, :account_deletion_hook, nil)
    :ok
  end

  test "the sweep's job deletes the due account and spares the one still in its grace period" do
    now = DateTime.utc_now(:second)
    overdue_at = DateTime.add(now, -1, :day)
    pending_at = DateTime.add(now, 3, :day)

    due = insert(:user, deletion_requested_at: overdue_at, deletion_scheduled_at: overdue_at)

    not_yet_due =
      insert(:user,
        deletion_requested_at: DateTime.add(now, -4, :day),
        deletion_scheduled_at: pending_at
      )

    assert :ok = perform_job(AccountDeletionSweepWorker, %{})

    assert [job] = all_enqueued(worker: AccountDeletionWorker)
    assert job.args == %{"user_id" => due.id}

    assert :ok = perform_job(AccountDeletionWorker, job.args)

    refute Repo.get(UserSchema, due.id)

    spared = Repo.get!(UserSchema, not_yet_due.id)
    assert spared.deletion_scheduled_at == pending_at
  end
end
