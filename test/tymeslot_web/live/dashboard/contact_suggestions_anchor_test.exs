defmodule TymeslotWeb.Dashboard.ContactSuggestionsAnchorTest do
  @moduledoc """
  The poll invitation field carries the contact suggestion anchor the
  `ContactSuggest` hook fills, adding to its list. The calendar's guest
  fields are covered by `CalendarSurfaceContactSuggestionsTest`.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :dashboard
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  setup :setup_dashboard_user

  test "the poll invitation field suggests contacts into its list", %{conn: conn, user: user} do
    # Polls are offered once the host has a calendar to put the meeting in.
    insert(:calendar_integration, user: user, provider: "debug")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/polls")
    lv |> element("button[phx-click='new_poll']") |> render_click()

    [id] = Regex.run(~r/id="(poll-invitees-[^"]+)"/, render(lv), capture: :all_but_first)

    assert has_element?(lv, ~s(##{id}-contact-suggest[data-mode="append"][data-input="#{id}"]))
  end
end
