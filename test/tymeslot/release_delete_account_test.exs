defmodule Tymeslot.ReleaseDeleteAccountTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Release
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AccountDeletionWorker

  defmodule RefusingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(_user_id, _feedback), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: {:error, :subscription_active}
  end

  setup do
    with_config(:tymeslot, :account_deletion_hook, nil)
    :ok
  end

  test "deletes the account with that address and waits for it" do
    user = insert(:user, email: "leaver@example.com")

    assert Release.delete_account("leaver@example.com") == {:ok, :deleted}
    refute Repo.get(UserSchema, user.id)
  end

  test "returns the error when the deletion hook refuses, leaving the account pending" do
    with_config(:tymeslot, :account_deletion_hook, RefusingHook)
    user = insert(:user, email: "leaver@example.com")

    assert Release.delete_account("leaver@example.com") == {:error, :subscription_active}

    assert Repo.get(UserSchema, user.id).deletion_scheduled_at
  end

  test "queues the retry job in the future so it cannot race the synchronous deletion" do
    with_config(:tymeslot, :account_deletion_hook, RefusingHook)
    user = insert(:user, email: "leaver@example.com")
    user_id = user.id

    assert {:error, :subscription_active} = Release.delete_account("leaver@example.com")

    assert [job] = all_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => user_id})
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) > 120
  end

  test "refuses the only admin without force" do
    insert(:user, is_admin: true, email: "root@example.com")

    assert Release.delete_account("root@example.com") == {:error, :last_admin}
  end

  test "reports an unknown address" do
    assert Release.delete_account("nobody@example.com") == {:error, :not_found}
  end
end
