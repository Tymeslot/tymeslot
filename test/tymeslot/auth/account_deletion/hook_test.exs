defmodule Tymeslot.Auth.AccountDeletion.HookTest do
  use ExUnit.Case, async: false

  @moduletag :auth
  @moduletag :unit

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Auth.AccountDeletion.Hook

  defmodule RecordingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(_user_id, %{reason: "raise"}), do: raise("hook exploded")
    def on_deletion_requested(_user_id, %{reason: "exit"}), do: exit(:hook_gone)
    def on_deletion_requested(_user_id, %{reason: "throw"}), do: throw(:hook_thrown)

    def on_deletion_requested(user_id, feedback) do
      send(self(), {:requested, user_id, feedback})
      :ok
    end

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(user_id) do
      send(self(), {:restored, user_id})
      {:error, :stripe_down}
    end

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(user_id) do
      send(self(), {:deleted, user_id})
      {:error, :stripe_down}
    end
  end

  defmodule ProtectingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(_user_id, _feedback), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def purge_protected_user_ids, do: Process.get(:protected).()
  end

  test "with no hook configured every call is a no-op" do
    with_config(:tymeslot, :account_deletion_hook, nil)

    assert Hook.requested(1, nil) == :ok
    assert Hook.restored(1) == :ok
    assert Hook.deleted(1) == :ok
  end

  test "passes the request and its feedback to the hook" do
    with_config(:tymeslot, :account_deletion_hook, RecordingHook)

    assert Hook.requested(7, %{reason: "other", comment: nil}) == :ok
    assert_received {:requested, 7, %{reason: "other", comment: nil}}
  end

  test "a failing restore callback is logged, never returned" do
    with_config(:tymeslot, :account_deletion_hook, RecordingHook)

    log = capture_log(fn -> assert Hook.restored(7) == :ok end)

    assert_received {:restored, 7}
    assert log =~ "Account deletion hook failed"
  end

  test "a request callback that raises is logged, never raised" do
    with_config(:tymeslot, :account_deletion_hook, RecordingHook)

    log =
      capture_log(fn ->
        assert Hook.requested(7, %{reason: "raise", comment: nil}) == :ok
      end)

    assert log =~ "Account deletion hook failed"
    assert log =~ "hook exploded"
  end

  test "a request callback that exits or throws is logged, never propagated" do
    with_config(:tymeslot, :account_deletion_hook, RecordingHook)

    exit_log =
      capture_log(fn -> assert Hook.requested(7, %{reason: "exit", comment: nil}) == :ok end)

    throw_log =
      capture_log(fn -> assert Hook.requested(7, %{reason: "throw", comment: nil}) == :ok end)

    assert exit_log =~ "Account deletion hook failed"
    assert exit_log =~ "hook_gone"
    assert throw_log =~ "Account deletion hook failed"
    assert throw_log =~ "hook_thrown"
  end

  test "a failing delete callback is returned so the deletion stops" do
    with_config(:tymeslot, :account_deletion_hook, RecordingHook)

    assert Hook.deleted(7) == {:error, :stripe_down}
    assert_received {:deleted, 7}
  end

  describe "purge_protected_user_ids/0" do
    test "protects nobody with no hook, or a hook without the callback" do
      with_config(:tymeslot, :account_deletion_hook, nil)
      assert Hook.purge_protected_user_ids() == {:ok, []}

      with_config(:tymeslot, :account_deletion_hook, RecordingHook)
      assert Hook.purge_protected_user_ids() == {:ok, []}
    end

    test "returns the ids the hook names" do
      with_config(:tymeslot, :account_deletion_hook, ProtectingHook)
      Process.put(:protected, fn -> {:ok, [3, 5]} end)

      assert Hook.purge_protected_user_ids() == {:ok, [3, 5]}
    end

    test "fails closed on an error, a raise, an exit, a throw or a malformed answer" do
      with_config(:tymeslot, :account_deletion_hook, ProtectingHook)

      failures = [
        fn -> {:error, :db_down} end,
        fn -> raise "boom" end,
        fn -> exit(:gone) end,
        fn -> throw(:thrown) end,
        fn -> {:ok, ["7"]} end,
        fn -> [7] end
      ]

      for failure <- failures do
        Process.put(:protected, failure)
        assert {:error, _reason} = Hook.purge_protected_user_ids()
      end
    end
  end
end
