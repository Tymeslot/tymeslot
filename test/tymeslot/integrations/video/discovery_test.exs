defmodule Tymeslot.Integrations.Video.DiscoveryTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Discovery

  describe "default_provider/0" do
    test "returns mirotalk as the default video provider" do
      assert Discovery.default_provider() == :mirotalk
    end
  end
end
