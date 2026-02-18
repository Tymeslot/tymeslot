defmodule Tymeslot.DemoTest do
  @moduletag :utils
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Demo

  describe "Demo facade" do
  @moduletag :utils
    test "delegates calls to the provider" do
      # Simple smoke test to ensure delegation works
      refute Demo.demo_mode?(%{})
      assert Demo.get_orchestrator(%{}) == Tymeslot.Bookings.Orchestrator
    end
  end
end
