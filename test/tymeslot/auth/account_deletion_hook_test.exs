defmodule Tymeslot.Auth.AccountDeletionHookTest do
  @moduledoc """
  Auth.delete_account/1 runs the configured account-deletion hook before
  touching the database. A failing hook must abort the deletion so a user is
  never destroyed while external state that keeps billing them (a live
  subscription) could not be torn down.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Tymeslot.Factory

  alias Phoenix.Socket.Broadcast
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{UserSchema, UserSessionQueries}
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token
  alias TymeslotWeb.Endpoint

  defmodule OkHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook
    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: :ok
  end

  defmodule FailingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook
    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
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

    assert {:ok, _deleted} = Auth.delete_account(user)
    refute Repo.get(UserSchema, user.id)
  end

  test "deletes the user when the hook succeeds" do
    Application.put_env(:tymeslot, :account_deletion_hook, OkHook)
    user = insert(:user)

    assert {:ok, _deleted} = Auth.delete_account(user)
    refute Repo.get(UserSchema, user.id)
  end

  test "aborts deletion and preserves the user when the hook fails" do
    Application.put_env(:tymeslot, :account_deletion_hook, FailingHook)
    user = insert(:user)

    assert {:error, :subscription_cancel_failed} = Auth.delete_account(user)
    assert Repo.get(UserSchema, user.id), "user must survive when external cleanup fails"
  end

  test "leaves the user's sessions connected when the hook fails" do
    Application.put_env(:tymeslot, :account_deletion_hook, FailingHook)
    user = insert(:user)
    token = "kept-session-#{System.unique_integer([:positive])}"
    insert(:user_session, user: user, token_hash: Token.hash_token(token))
    Endpoint.subscribe("users_sessions:#{Base.url_encode64(Token.hash_token(token))}")

    assert {:error, :subscription_cancel_failed} = Auth.delete_account(user)

    refute_receive %Broadcast{event: "disconnect"}
    assert UserSessionQueries.get_user_by_session_token(token)
  end
end
