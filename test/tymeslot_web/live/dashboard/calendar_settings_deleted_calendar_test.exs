defmodule TymeslotWeb.Dashboard.CalendarSettingsDeletedCalendarTest do
  @moduledoc """
  A calendar deleted in another tab after the settings page loaded: acting on
  it tells the owner it is no longer available, not an internal reason.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Repo

  setup :setup_dashboard_user

  test "switching a calendar deleted in another tab says it is no longer available",
       %{conn: conn, user: user} do
    integration = insert(:calendar_integration, user: user, provider: "google")

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
    Repo.delete!(integration)

    view
    |> element("#toggle-#{integration.id}")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "This calendar integration is no longer available."
    refute rendered =~ "Failed to update status"
  end
end
