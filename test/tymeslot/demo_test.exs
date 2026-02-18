defmodule Tymeslot.DemoTest do
  use Tymeslot.DataCase, async: true

  @moduletag :utils

  alias Tymeslot.Demo

  describe "Demo facade" do
    test "delegates calls to the provider" do
      # Simple smoke test to ensure delegation works
      refute Demo.demo_mode?(%{})
      assert Demo.get_orchestrator(%{}) == Tymeslot.Bookings.Orchestrator
    end
  end
end
