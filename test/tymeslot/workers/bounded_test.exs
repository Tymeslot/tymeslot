defmodule Tymeslot.Workers.BoundedTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  import Tymeslot.Factory

  alias Tymeslot.Workers.Bounded

  test "returns the work's result" do
    assert {:ok, 42} = Bounded.run(fn -> 42 end, 1_000)
  end

  test "stops work that outlives its deadline" do
    test_pid = self()

    assert :timeout =
             Bounded.run(
               fn ->
                 send(test_pid, {:worker, self()})
                 Process.sleep(:infinity)
               end,
               50
             )

    assert_received {:worker, worker}
    refute Process.alive?(worker)
  end

  # Unlinked, so the crash is the worker's to report (redacted), not a raw
  # exit that kills the job.
  test "returns a crash as a value without taking the caller down" do
    assert {:exit, {%RuntimeError{message: "boom"}, _stack}} =
             Bounded.run(fn -> raise "boom" end, 1_000)

    assert Process.alive?(self())
  end

  # Tests run the same path as production: the work reaches the test's
  # sandboxed connection through `$callers`.
  test "the work sees the caller's database sandbox" do
    user = insert(:user)

    assert {:ok, %{id: id}} =
             Bounded.run(fn -> Repo.get!(Tymeslot.Auth.UserSchema, user.id) end, 1_000)

    assert id == user.id
  end
end
