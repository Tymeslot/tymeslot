defmodule TymeslotWeb.Helpers.PageTitlesTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias TymeslotWeb.Helpers.PageTitles

  test ":calendar returns the calendar grid title" do
    assert PageTitles.dashboard_title(:calendar) == "Calendar - Dashboard"
  end

  test ":calendar_integration returns the integration settings title" do
    assert PageTitles.dashboard_title(:calendar_integration) == "Calendar Integration - Dashboard"
  end

  test ":video_integration returns the video integration title" do
    assert PageTitles.dashboard_title(:video_integration) == "Video Integration - Dashboard"
  end
end
