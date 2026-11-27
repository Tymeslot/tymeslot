defmodule TymeslotWeb.Dashboard.MeetingTypeFormRedirectTest do
  @moduledoc """
  The meeting type form's redirect section: the address a new booking sends
  its booker to, and the switch passing the booking's details along. Both
  auto-save; an address that is not a full web address is refused beside
  the input, never saved, and never blocks the saving of other changes.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  setup %{user: user} do
    %{meeting_type: insert(:meeting_type, user: user, name: "Discovery Call")}
  end

  defp open_form(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  defp type_url(view, url) do
    view
    |> element("[data-testid='redirect-url']")
    |> render_change(%{"meeting_type" => %{"redirect_url" => url}})
  end

  defp saved(meeting_type),
    do: MeetingTypes.get_meeting_type(meeting_type.id, meeting_type.user_id)

  test "is offered on the booking rules tab", %{conn: conn, meeting_type: meeting_type} do
    view = open_form(conn, meeting_type)

    assert has_element?(
             view,
             "#meeting-type-form-tabs-panel-booking [data-testid='redirect-url']"
           )

    html = render(view)
    assert html =~ "Pass event details to your redirected page"

    assert html =~
             "Include booking info like invitee name, email, and event time in the redirect URL"
  end

  test "saves a valid address and the switch", %{conn: conn, meeting_type: meeting_type} do
    view = open_form(conn, meeting_type)

    type_url(view, " https://example.com/thanks?src=tymeslot ")
    view |> element("[data-testid='redirect-pass-details-toggle']") |> render_click()

    saved = saved(meeting_type)
    assert saved.redirect_url == "https://example.com/thanks?src=tymeslot"
    assert saved.redirect_pass_details
  end

  test "refuses an invalid address beside the input and keeps the stored one",
       %{conn: conn, meeting_type: meeting_type} do
    {:ok, _type} =
      MeetingTypes.update_meeting_type(meeting_type, %{redirect_url: "https://example.com/ok"})

    view = open_form(conn, meeting_type)

    html = type_url(view, "javascript:alert(1)")

    assert html =~ "must be a full web address starting with http:// or https://"
    assert html =~ "Unsaved changes"
    assert saved(meeting_type).redirect_url == "https://example.com/ok"

    # Another change still saves, with the stored address, and the refusal
    # stays shown until the address is fixed.
    html = view |> element("[data-testid='redirect-pass-details-toggle']") |> render_click()

    assert saved(meeting_type).redirect_pass_details
    assert saved(meeting_type).redirect_url == "https://example.com/ok"
    assert html =~ "must be a full web address starting with http:// or https://"

    html = type_url(view, "https://example.com/fixed")

    refute html =~ "must be a full web address"
    assert saved(meeting_type).redirect_url == "https://example.com/fixed"
  end

  test "clearing the address turns the redirect off", %{conn: conn, meeting_type: meeting_type} do
    {:ok, _type} =
      MeetingTypes.update_meeting_type(meeting_type, %{redirect_url: "https://example.com/ok"})

    conn |> open_form(meeting_type) |> type_url("")

    assert saved(meeting_type).redirect_url == nil
  end
end
