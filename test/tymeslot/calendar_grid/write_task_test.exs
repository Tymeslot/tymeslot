defmodule Tymeslot.CalendarGrid.WriteTaskTest do
  @moduledoc """
  A calendar write runs in a supervised task and always answers the process
  that started it, with its result or, if it crashed, the crash result.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  import ExUnit.CaptureLog

  alias Tymeslot.CalendarGrid.WriteTask

  test "sends the result back tagged" do
    assert :ok = WriteTask.start(:event_update_result, fn -> {:ok, :written} end, :crashed)
    assert_receive {:event_update_result, {:ok, :written}}
  end

  test "sends the crash result when the write raises" do
    capture_log(fn ->
      assert :ok =
               WriteTask.start(:event_update_result, fn -> raise "boom" end, {:error, :crashed})

      assert_receive {:event_update_result, {:error, :crashed}}
    end)
  end

  test "a {tag, ref} tag answers with the ref, so many of one kind can run at once" do
    assert :ok = WriteTask.start({:calendar_create_result, "d1"}, fn -> {:ok, :one} end, :crashed)
    assert :ok = WriteTask.start({:calendar_create_result, "d2"}, fn -> {:ok, :two} end, :crashed)

    assert_receive {:calendar_create_result, "d1", {:ok, :one}}
    assert_receive {:calendar_create_result, "d2", {:ok, :two}}
  end

  test "a {tag, ref} tag answers with the ref and the crash result when the write raises" do
    capture_log(fn ->
      assert :ok =
               WriteTask.start({:calendar_create_result, "d1"}, fn -> raise "boom" end, :crashed)

      assert_receive {:calendar_create_result, "d1", :crashed}
    end)
  end
end
