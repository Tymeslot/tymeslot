defmodule TymeslotWeb.Dashboard.MeetingSettings.HelpersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :meeting_types

  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  describe "format_errors/1" do
    test "formats list of errors" do
      assert Helpers.format_errors(["error 1", "error 2"]) == "error 1, error 2"
    end

    test "formats single string error" do
      assert Helpers.format_errors("single error") == "single error"
    end

    test "handles other types" do
      assert Helpers.format_errors(nil) == "An error occurred"
    end
  end
end
