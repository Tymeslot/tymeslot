defmodule TymeslotWeb.Dashboard.ContactSuggestionsAnchorTest do
  @moduledoc """
  The invite fields carry the contact suggestion anchor the `ContactSuggest`
  hook fills: under Quick Add's main guest (filling the name too), its extra
  guests (submitting the Add form), and the poll invitation field (adding to
  the list).
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :dashboard
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  setup :setup_dashboard_user

  test "Quick add's guest fields suggest contacts", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")
    lv |> element("#calendar-grid") |> render_hook("show_create_form", %{})

    assert has_element?(
             lv,
             ~s(#create-meeting-guest-email-contact-suggest[phx-hook="ContactSuggest"][data-input="create-meeting-guest-email"][data-name-input="create-meeting-guest-name"])
           )

    assert has_element?(
             lv,
             ~s(#create-guest-email-input-contact-suggest[data-input="create-guest-email-input"][data-submit])
           )

    assert has_element?(lv, ~s(#create-meeting-guest-email[autocomplete="off"]))
  end

  test "the poll invitation field suggests contacts into its list", %{conn: conn, user: user} do
    # Polls are offered once the host has a calendar to put the meeting in.
    insert(:calendar_integration, user: user, provider: "debug")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/polls")
    lv |> element("button[phx-click='new_poll']") |> render_click()

    [id] = Regex.run(~r/id="(poll-invitees-[^"]+)"/, render(lv), capture: :all_but_first)

    assert has_element?(lv, ~s(##{id}-contact-suggest[data-mode="append"][data-input="#{id}"]))
  end
end
