defmodule TymeslotWeb.Components.UIExtendedTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias TymeslotWeb.Components.Shared.TimeOptions

  describe "TimeOptions" do
    test "time_options/1 returns 24h interval pairs" do
      options = TimeOptions.time_options("24h")
      assert length(options) == 24 * 4
      assert {"00:00", "00:00"} = hd(options)
      assert {"23:45", "23:45"} = List.last(options)
    end
  end
end
