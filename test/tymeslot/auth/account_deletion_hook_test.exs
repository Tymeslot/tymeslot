defmodule Tymeslot.Auth.AccountDeletionHookTest do
  @moduledoc """
  delete_user/1 runs the configured account-deletion hook before touching the
  database. A failing hook must abort the deletion so a user is never destroyed
  while external state that keeps billing them (a live subscription) could not
  be torn down.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Tymeslot.Factory

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo

  defmodule OkHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook
    @impl true
    def on_account_deletion(_user_id), do: :ok
  end

  defmodule FailingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook
    @impl true
    def on_account_deletion(_user_id), do: {:error, :subscription_cancel_failed}
  end

  setup do
    original = Application.get_env(:tymeslot, :account_deletion_hook)
    on_exit(fn -> Application.put_env(:tymeslot, :account_deletion_hook, original) end)
    :ok
  end

  test "deletes the user when no hook is configured" do
    Application.put_env(:tymeslot, :account_deletion_hook, nil)
    user = insert(:user)

    assert {:ok, _deleted} = UserQueries.delete_user(user)
    refute Repo.get(UserSchema, user.id)
  end

  test "deletes the user when the hook succeeds" do
    Application.put_env(:tymeslot, :account_deletion_hook, OkHook)
    user = insert(:user)

    assert {:ok, _deleted} = UserQueries.delete_user(user)
    refute Repo.get(UserSchema, user.id)
  end

  test "aborts deletion and preserves the user when the hook fails" do
    Application.put_env(:tymeslot, :account_deletion_hook, FailingHook)
    user = insert(:user)

    assert {:error, :subscription_cancel_failed} = UserQueries.delete_user(user)
    assert Repo.get(UserSchema, user.id), "user must survive when external cleanup fails"
  end
end
