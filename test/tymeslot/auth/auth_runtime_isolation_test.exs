defmodule Tymeslot.Auth.AuthRuntimeIsolationTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import ExUnit.CaptureLog
  import Mox

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.Security.Token

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tymeslot, :user_broadcaster)
    Application.put_env(:tymeslot, :user_broadcaster, Tymeslot.Auth.UserBroadcasterMock)

    on_exit(fn ->
      if original do
        Application.put_env(:tymeslot, :user_broadcaster, original)
      else
        Application.delete_env(:tymeslot, :user_broadcaster)
      end
    end)

    :ok
  end

  describe "verify_user_email/1 runtime isolation" do
    # Regression test for Task 94: the registration broadcast must run under
    # Tymeslot.TaskSupervisor so that a broadcast failure cannot take down
    # the caller of Auth.verify_user_email/1.
    test "returns {:ok, user} even when the async broadcast crashes" do
      user = insert(:unverified_user)
      {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
      {:ok, _updated} = UserTokenQueries.set_verification_token(user, token)

      test_pid = self()

      stub(Tymeslot.Auth.UserBroadcasterMock, :broadcast_user_registered, fn _user ->
        send(test_pid, {:task_pid, self()})
        raise "simulated broadcast failure"
      end)

      log =
        capture_log(fn ->
          # The outer verification must succeed even though the supervised
          # broadcast task will raise in a separate process.
          assert {:ok, verified_user} = Auth.verify_user_email(token)
          assert verified_user.id == user.id

          # Receive the task pid from inside the supervised task body, then
          # monitor it. The :DOWN message is only delivered after the process
          # has fully terminated and the supervisor has processed the exit —
          # which is after the crash report has been emitted into the logger.
          assert_receive {:task_pid, task_pid}, 500
          ref = Process.monitor(task_pid)
          assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 500
        end)

      assert log =~ "simulated broadcast failure"
    end
  end
end
