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

    # Should see the new type in the list (name is in an h3)
    assert_has(session, css("h3", text: "Quick Chat"))
  end
end
