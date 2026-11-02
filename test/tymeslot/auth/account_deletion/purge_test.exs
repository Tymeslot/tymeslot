defmodule Tymeslot.Auth.AccountDeletion.PurgeTest do
  # The deletion hook is global config, so this module cannot run async.
  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Auth.AccountDeletion
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  # Answers from the test process's dictionary, so each test sets what the
  # deployment protects and what happens while the hook runs.
  defmodule ProtectingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(_user_id, _feedback), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(user_id) do
      send(self(), {:hook_deleted, user_id})
      Process.get(:during_hook, fn -> :ok end).()
      :ok
    end

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def purge_protected_user_ids, do: Process.get(:protected, fn -> {:ok, []} end).()
  end

  setup do
    with_config(:tymeslot, :account_deletion_hook, ProtectingHook)
    :ok
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(:second), -days, :day)
  defp cutoff, do: days_ago(30)

  describe "purge_unverified_accounts/1 and the deployment's protected accounts" do
    test "never deletes an account the hook protects, and deletes the rest" do
      protected = insert(:unverified_user, inserted_at: days_ago(400))
      abandoned = insert(:unverified_user, inserted_at: days_ago(400))
      Process.put(:protected, fn -> {:ok, [protected.id]} end)

      assert AccountDeletion.purge_unverified_accounts(30) == {1, nil}

      assert Repo.get(UserSchema, protected.id)
      refute Repo.get(UserSchema, abandoned.id)
      protected_id = protected.id
      refute_received {:hook_deleted, ^protected_id}
    end

    test "a protected account takes no place in the batch" do
      protected = insert(:unverified_user, inserted_at: days_ago(400))
      younger = insert(:unverified_user, inserted_at: days_ago(100))

      assert [%UserSchema{id: id}] =
               UserQueries.list_stale_unverified_users(cutoff(), 1, [protected.id])

      assert id == younger.id
    end

    test "deletes nothing when the hook reports an error" do
      user = insert(:unverified_user, inserted_at: days_ago(400))
      Process.put(:protected, fn -> {:error, :saas_db_down} end)

      LogCapture.attach()
      assert AccountDeletion.purge_unverified_accounts(30) == {0, nil}

      assert LogCapture.await_log("Skipped the purge of unverified accounts").level == :error
      assert Repo.get(UserSchema, user.id)
      refute_received {:hook_deleted, _id}
    end

    test "deletes nothing when the hook raises or exits" do
      user = insert(:unverified_user, inserted_at: days_ago(400))

      for failure <- [fn -> raise "boom" end, fn -> exit(:gone) end, fn -> :not_a_list end] do
        Process.put(:protected, failure)
        assert AccountDeletion.purge_unverified_accounts(30) == {0, nil}
      end

      assert Repo.get(UserSchema, user.id)
      refute_received {:hook_deleted, _id}
    end

    test "logs each purged account by id" do
      user = insert(:unverified_user, inserted_at: days_ago(400))

      LogCapture.with_capture([logger_level: :info], fn ->
        assert AccountDeletion.purge_unverified_accounts(30) == {1, nil}
      end)

      event = LogCapture.await_log("Purged an unverified account")
      assert LogCapture.user_metadata(event).user_id == user.id
    end
  end

  describe "erase_account/2 with only_if_purgeable:" do
    test "an account no longer purgeable keeps its grants and never reaches the hook" do
      user = insert(:user, inserted_at: days_ago(400))
      slack = insert(:slack_integration, user: user)
      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
        send(test_pid, {:post, url})
        {:ok, %Req.Response{status: 200, body: ""}}
      end)

      assert AccountDeletion.erase_account(user, only_if_purgeable: cutoff()) ==
               {:error, :not_purgeable}

      assert Repo.get(UserSchema, user.id)
      assert Repo.get(SlackIntegrationSchema, slack.id)
      refute_received {:post, _url}
      refute_received {:hook_deleted, _id}
    end
  end

  describe "delete_account/2 with only_if_purgeable:" do
    test "stops if the account is verified while the deletion runs" do
      user = insert(:unverified_user, inserted_at: days_ago(400))

      Process.put(:during_hook, fn ->
        user |> Changeset.change(verified_at: DateTime.utc_now(:second)) |> Repo.update!()
      end)

      assert AccountDeletion.delete_account(user, only_if_purgeable: cutoff()) ==
               {:error, :not_purgeable}

      user_id = user.id
      assert_received {:hook_deleted, ^user_id}
      assert Repo.get(UserSchema, user.id).verified_at
    end

    test "stops if the account is made an admin while the deletion runs" do
      user = insert(:unverified_user, inserted_at: days_ago(400))

      Process.put(:during_hook, fn ->
        user |> Changeset.change(is_admin: true) |> Repo.update!()
      end)

      assert AccountDeletion.delete_account(user, only_if_purgeable: cutoff()) ==
               {:error, :not_purgeable}

      assert Repo.get(UserSchema, user.id)
    end

    test "stops if a meeting still to come is booked while the deletion runs" do
      user = insert(:unverified_user, inserted_at: days_ago(400))
      starts = DateTime.add(DateTime.utc_now(:second), 2, :day)

      Process.put(:during_hook, fn ->
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          status: :confirmed,
          start_time: starts,
          end_time: DateTime.add(starts, 30, :minute)
        )
      end)

      assert AccountDeletion.delete_account(user, only_if_purgeable: cutoff()) ==
               {:error, :not_purgeable}

      assert Repo.get(UserSchema, user.id)
    end

    test "does not run the hook for an account already ineligible" do
      user = insert(:unverified_user, inserted_at: days_ago(400), is_admin: true)

      assert AccountDeletion.delete_account(user, only_if_purgeable: cutoff()) ==
               {:error, :not_purgeable}

      refute_received {:hook_deleted, _id}
    end

    test "deletes an account still purgeable" do
      user = insert(:unverified_user, inserted_at: days_ago(400))

      assert {:ok, _deleted} = AccountDeletion.delete_account(user, only_if_purgeable: cutoff())
      refute Repo.get(UserSchema, user.id)
    end
  end
end
