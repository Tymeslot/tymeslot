defmodule Tymeslot.Auth.AccountDeletion.RestoreTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AccountDeletionWorker

  defmodule RecordingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(_user_id, _feedback), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(user_id) do
      send(self(), {:restored, user_id})
      :ok
    end

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: :ok
  end

  setup do
    with_config(:tymeslot, :account_deletion_hook, RecordingHook)
    :ok
  end

  test "clears the schedule, removes the waiting job and tells the hook" do
    at = DateTime.add(DateTime.utc_now(:second), 14, :day)

    user =
      insert(:user, deletion_requested_at: DateTime.utc_now(:second), deletion_scheduled_at: at)

    user_id = user.id
    {:ok, _job} = AccountDeletionWorker.schedule(user.id, at)

    assert {:ok, restored} = Auth.restore_account(user)

    assert restored.deletion_scheduled_at == nil
    assert restored.deletion_requested_at == nil
    refute_enqueued(worker: AccountDeletionWorker)
    assert_received {:restored, ^user_id}
  end

  test "refuses an account that is not pending deletion" do
    assert Auth.restore_account(insert(:user)) == {:error, :not_pending}
    refute_received {:restored, _user_id}
  end

  test "refuses once the grace period is over and changes nothing" do
    due = DateTime.add(DateTime.utc_now(:second), -1, :second)

    user =
      insert(:user,
        deletion_requested_at: DateTime.add(due, -14, :day),
        deletion_scheduled_at: due
      )

    user_id = user.id
    {:ok, _job} = AccountDeletionWorker.schedule(user.id, due)

    assert Auth.restore_account(user) == {:error, :deletion_in_progress}

    assert Repo.get(UserSchema, user_id).deletion_scheduled_at == due
    assert_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => user_id})
    refute_received {:restored, _user_id}
  end
end
