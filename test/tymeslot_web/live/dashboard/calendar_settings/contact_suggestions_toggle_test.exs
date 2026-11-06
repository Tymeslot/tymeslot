defmodule TymeslotWeb.Dashboard.CalendarSettings.ContactSuggestionsToggleTest do
  @moduledoc """
  Turning contact suggestions on and off on a calendar connection's card,
  offered only where the server keeps address books beside its calendars.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integrations
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Repo

  setup :setup_dashboard_user

  defp open_calendars(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
    view
  end

  defp toggle(integration),
    do: "[data-testid='use-for-contacts-toggle'][phx-value-id='#{integration.id}']"

  test "turns suggestions on and off on a CalDAV connection", %{conn: conn, user: user} do
    integration = insert(:calendar_integration, user: user, provider: "nextcloud")
    view = open_calendars(conn)

    assert has_element?(view, "#{toggle(integration)}[aria-pressed='false']")

    view |> element(toggle(integration)) |> render_click()

    assert Repo.reload!(integration).use_for_contacts
    assert has_element?(view, "#{toggle(integration)}[aria-pressed='true']")
    assert render(view) =~ "Contacts from this account are now suggested"

    view |> element(toggle(integration)) |> render_click()

    refute Repo.reload!(integration).use_for_contacts
    assert has_element?(view, "#{toggle(integration)}[aria-pressed='false']")
  end

  test "is not offered on a connection without address books", %{conn: conn, user: user} do
    google = insert(:calendar_integration, user: user, provider: "google")
    view = open_calendars(conn)

    refute has_element?(view, toggle(google))
  end
end
