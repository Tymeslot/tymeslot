defmodule Tymeslot.Infrastructure.BestEffortTest do
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.BestEffort
  alias Tymeslot.Test.LogCapture

  @message "Cleanup step failed; carrying on"

  setup do
    LogCapture.attach(level: :warning)
    :ok
  end

  test "a step that succeeds, whatever it answers, logs nothing" do
    for result <- [:ok, {:ok, :done}, nil] do
      assert BestEffort.run(:step, fn -> result end, @message) == :ok
    end

    refute_received {:captured_log, %{meta: %{step: :step}}}
  end

  test "an error result is logged with the step, the caller's metadata and the reason" do
    assert BestEffort.run(:revoke, fn -> {:error, :timeout} end, @message, user_id: 7) == :ok

    meta = @message |> LogCapture.await_log() |> LogCapture.user_metadata()
    assert %{step: :revoke, user_id: 7, reason: ":timeout"} = meta
  end

  test "a raise is logged with the exception module and its stacktrace" do
    assert BestEffort.run(:revoke, fn -> raise ArgumentError, "bad" end, @message) == :ok

    meta = @message |> LogCapture.await_log() |> LogCapture.user_metadata()
    assert %{step: :revoke, exception: "ArgumentError", stacktrace: stacktrace} = meta
    assert stacktrace =~ "best_effort_test.exs"
  end

  test "an exit and a throw are logged with their kind" do
    assert BestEffort.run(:a, fn -> exit(:lock_timeout) end, @message) == :ok
    assert %{reason: "{:exit, :lock_timeout}"} = await_metadata()

    assert BestEffort.run(:b, fn -> throw(:gave_up) end, @message) == :ok
    assert %{reason: "{:throw, :gave_up}"} = await_metadata()
  end

  defp await_metadata, do: @message |> LogCapture.await_log() |> LogCapture.user_metadata()
end
