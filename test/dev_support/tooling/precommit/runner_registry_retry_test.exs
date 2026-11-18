defmodule Tymeslot.Precommit.RunnerRegistryRetryTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.Precommit.Runner

  describe "retry_registry/3" do
    @timeout_output "Failed to fetch record for floki from registry (using cache instead)\n:timeout\n"

    # Hands out the scripted results one per call, counting the calls.
    defp scripted(results) do
      {:ok, agent} = Agent.start_link(fn -> results end)

      run = fn -> Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end) end
      {run, agent}
    end

    test "retries a registry timeout until the audit passes" do
      {run, _agent} = scripted([{@timeout_output, 1}, {@timeout_output, 1}, {"ok\n", 0}])

      assert {"ok\n", 0} = Runner.retry_registry(run, 3, 0)
    end

    test "gives up after the last attempt and returns the failure" do
      {run, agent} = scripted([{@timeout_output, 1}, {@timeout_output, 1}, {@timeout_output, 1}])

      assert {@timeout_output, 1} = Runner.retry_registry(run, 3, 0)
      assert Agent.get(agent, & &1) == []
    end

    test "does not retry a failure that is not a registry timeout" do
      {run, agent} = scripted([{"vulnerable: plug 1.0\n", 1}, {"ok\n", 0}])

      assert {"vulnerable: plug 1.0\n", 1} = Runner.retry_registry(run, 3, 0)
      assert Agent.get(agent, & &1) == [{"ok\n", 0}]
    end
  end
end
