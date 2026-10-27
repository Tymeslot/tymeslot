defmodule Tymeslot.Auth.AccountDeletion.OperatorTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Auth.UserSessionQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token
  alias Tymeslot.Workers.AccountDeletionWorker

  setup do
    with_config(:tymeslot, enable_admin_ui: true, account_deletion_hook: nil)
    :ok
  end

  test "an admin deletes another account now" do
    admin = insert(:user, is_admin: true)
    target = insert(:user)
    target_id = target.id

    assert {:ok, pending} = Auth.delete_account_now(admin, target.id)

    assert DateTime.diff(DateTime.utc_now(), pending.deletion_scheduled_at) in 0..5
    assert [%{args: %{"user_id" => ^target_id}}] = all_enqueued(worker: AccountDeletionWorker)
  end

  test "replaces a self-service schedule with an immediate one" do
    admin = insert(:user, is_admin: true)
    later = DateTime.add(DateTime.utc_now(:second), 14, :day)

    target =
      insert(:user,
        deletion_requested_at: DateTime.utc_now(:second),
        deletion_scheduled_at: later
      )

    {:ok, _job} = AccountDeletionWorker.schedule(target.id, later)

    assert {:ok, pending} = Auth.delete_account_now(admin, target.id)

    assert DateTime.compare(pending.deletion_scheduled_at, later) == :lt
    assert [job] = all_enqueued(worker: AccountDeletionWorker)
    assert DateTime.compare(job.scheduled_at, later) == :lt
  end

  test "ends the target's sessions and leaves other users' alone" do
    admin = insert(:user, is_admin: true)
    target = insert(:user)
    bystander = insert(:user)
    insert(:user_session, user: target, token_hash: Token.hash_token("target-token"))
    insert(:user_session, user: bystander, token_hash: Token.hash_token("bystander-token"))

    assert {:ok, _pending} = Auth.delete_account_now(admin, target.id)

    refute UserSessionQueries.get_user_by_session_token("target-token")
    assert UserSessionQueries.get_user_by_session_token("bystander-token")
  end

  test "an admin demoted since their struct was loaded is forbidden" do
    stale_admin = insert(:user, is_admin: true)
    insert(:user, is_admin: true)
    target = insert(:user)

    stale_admin |> Changeset.change(is_admin: false) |> Repo.update!()

    assert Auth.delete_account_now(stale_admin, target.id) == {:error, :forbidden}
    refute Repo.get!(UserSchema, target.id).deletion_scheduled_at
  end

  test "an admin cannot delete themselves" do
    admin = insert(:user, is_admin: true)
    insert(:user, is_admin: true)

    assert Auth.delete_account_now(admin, admin.id) == {:error, :self}
  end

  test "a non-admin cannot delete anyone" do
    assert Auth.delete_account_now(insert(:user), insert(:user).id) == {:error, :forbidden}
  end

  test "the admin UI switch gates admin actors but not the release shell" do
    with_config(:tymeslot, :enable_admin_ui, false)
    admin = insert(:user, is_admin: true)
    target = insert(:user)

    assert Auth.delete_account_now(admin, target.id) == {:error, :admin_ui_disabled}
    assert {:ok, _pending} = Auth.delete_account_now(:cli, target.id)
  end

  test "the release shell needs force to delete the last admin" do
    only_admin = insert(:user, is_admin: true)

    assert Auth.delete_account_now(:cli, only_admin.id) == {:error, :last_admin}
    assert {:ok, _pending} = Auth.delete_account_now(:cli, only_admin.id, force: true)
  end

  test "an admin nobody can sign in with does not count towards the last admin" do
    target = insert(:user, is_admin: true)
    _unverified = insert(:unverified_user, is_admin: true)

    assert Auth.delete_account_now(:cli, target.id) == {:error, :last_admin}
    refute Repo.reload!(target).deletion_scheduled_at
  end

  test "force is the release shell's alone: an admin passing it is still refused" do
    actor = insert(:unverified_user, is_admin: true)
    target = insert(:user, is_admin: true)

    assert Auth.delete_account_now(actor, target.id, force: true) == {:error, :last_admin}
    refute Repo.reload!(target).deletion_scheduled_at
  end

  test "a forced release-shell deletion carries force into its fallback job" do
    only_admin = insert(:user, is_admin: true)
    later = DateTime.add(DateTime.utc_now(:second), 5, :minute)

    assert {:ok, _pending} =
             Auth.delete_account_now(:cli, only_admin.id, force: true, job_at: later)

    assert [%{args: %{"force" => true} = args}] = all_enqueued(worker: AccountDeletionWorker)

    # The job runs as the fallback would: the last admin is deleted, not held.
    assert :ok = perform_job(AccountDeletionWorker, args)
    refute Repo.get(UserSchema, only_admin.id)
  end

  test "an admin passing force queues a job without it" do
    actor = insert(:user, is_admin: true)
    _other_admin = insert(:user, is_admin: true)
    target = insert(:user)

    assert {:ok, _pending} = Auth.delete_account_now(actor, target.id, force: true)
    assert [%{args: args}] = all_enqueued(worker: AccountDeletionWorker)
    refute Map.has_key?(args, "force")
  end

  test "an unforced deletion queues a job without force" do
    target = insert(:user)
    _admin = insert(:user, is_admin: true)

    assert {:ok, _pending} = Auth.delete_account_now(:cli, target.id)
    assert [%{args: args}] = all_enqueued(worker: AccountDeletionWorker)
    refute Map.has_key?(args, "force")
  end
end
