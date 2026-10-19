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
end
