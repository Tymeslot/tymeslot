defmodule TymeslotWeb.E2E.CreateEventTypeTest do
  use TymeslotWeb.BrowserCase

  @moduletag :e2e

  feature "user can create a meeting type from the dashboard", %{session: session} do
    {session, _user} = log_in_via_browser(session)

    session =
      session
      |> visit("/dashboard/meeting-settings")
      |> wait_for_live()
      |> click(css("button", text: "Add Meeting Type"))
      |> fill_in(css("input[name='meeting_type[name]']"), with: "Quick Chat")
      |> fill_in(css("input[name='meeting_type[duration]']"), with: "30")
      |> click(css("button[type='submit']", text: "Create Meeting Type"))

    # Should see success flash and the new type in the list
    assert_has(session, css("div", text: "Quick Chat"))
  end
end
