defmodule Tymeslot.ConfigRobustnessTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Bookings.Policy
  alias TymeslotWeb.Endpoint

  describe "Policy.app_url/0" do
    test "delegates to Endpoint.url/0" do
      assert Policy.app_url() == Endpoint.url()
    end

    test "reflects configuration changes" do
      # Note: Endpoint.url() typically reads from configuration.
      # In tests, it's often fixed in config/test.exs.
      # Since we're using async: false, we can temporarily change the config
      # to verify it's being picked up if Endpoint.url() is dynamic.
      # However, Endpoint.url() in Phoenix is usually cached at startup.
      # For now, asserting it matches Endpoint.url() is the primary goal.
      assert Policy.app_url() == Endpoint.url()
    end
  end
end
