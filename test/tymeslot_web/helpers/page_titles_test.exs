defmodule TymeslotWeb.Helpers.PageTitlesTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias TymeslotWeb.Helpers.PageTitles

  test ":calendar returns the bare dashboard title as the landing mode" do
    assert PageTitles.dashboard_title(:calendar) == "Dashboard"
  end

  test ":overview returns the overview section title" do
    assert PageTitles.dashboard_title(:overview) == "Overview - Dashboard"
  end

  test ":calendar_integration returns the integration settings title" do
    assert PageTitles.dashboard_title(:calendar_integration) == "Calendar Integration - Dashboard"
  end

  test ":video_integration returns the video integration title" do
    assert PageTitles.dashboard_title(:video_integration) == "Video Integration - Dashboard"
  end
end
