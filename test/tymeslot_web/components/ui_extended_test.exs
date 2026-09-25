defmodule TymeslotWeb.Components.UIExtendedTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Navigation
  alias TymeslotWeb.Components.Shared.TimeOptions

  describe "TimeOptions" do
    test "time_options/1 returns 24h interval pairs" do
      options = TimeOptions.time_options("24h")
      assert length(options) == 24 * 4
      assert {"00:00", "00:00"} = hd(options)
      assert {"23:45", "23:45"} = List.last(options)
    end
  end

  describe "CoreComponents.Navigation" do
    test "detail_row/1 renders correctly" do
      assigns = %{label: "Test Label", value: "Test Value"}
      html = render_component(&Navigation.detail_row/1, assigns)
      assert html =~ "Test Label"
      assert html =~ "Test Value"
    end
  end
end
