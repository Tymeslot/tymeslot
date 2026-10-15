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

  test "every dashboard section names itself the way the sidebar does" do
    expected = %{
      overview: "Overview - Dashboard",
      meetings: "Meetings - Dashboard",
      analytics: "Analytics - Dashboard",
      meeting_settings: "Meeting Types - Dashboard",
      locations: "Locations - Dashboard",
      availability: "Availability - Dashboard",
      polls: "Polls - Dashboard",
      theme: "Theme - Dashboard",
      theme_customization: "Theme - Dashboard",
      integrations: "Integrations - Dashboard",
      embed: "Embed & Share - Dashboard",
      settings: "Profile - Dashboard",
      automation: "Automation - Dashboard"
    }

    assert Map.new(expected, fn {action, _title} ->
             {action, PageTitles.dashboard_title(action)}
           end) ==
             expected
  end
end
