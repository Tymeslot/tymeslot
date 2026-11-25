defmodule Tymeslot.DemoTest do
  # The demo provider is application config, so the test that swaps it cannot
  # run alongside tests that read the default one.
  use Tymeslot.DataCase, async: false

  @moduletag :utils

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Bookings.DemoOrchestrator
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Demo

  defmodule SimulatingProvider do
    @spec get_orchestrator(map()) :: module() | :default
    def get_orchestrator(%{simulate: true}), do: DemoOrchestrator
    def get_orchestrator(_context), do: :default
  end

  describe "get_orchestrator/1" do
    test "resolves the default provider's :default to Core's real orchestrator" do
      assert Demo.get_orchestrator(%{}) == Orchestrator
    end

    test "passes a provider's own submitter through and resolves its :default" do
      with_config(:tymeslot, demo_provider: SimulatingProvider)

      assert Demo.get_orchestrator(%{simulate: true}) == DemoOrchestrator
      assert Demo.get_orchestrator(%{}) == Orchestrator
    end
  end
end
