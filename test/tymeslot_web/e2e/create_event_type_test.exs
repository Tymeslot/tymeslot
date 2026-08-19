defmodule TymeslotWeb.E2E.CreateEventTypeTest do
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :meeting_types

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
    session = assert_has(session, css("h3", text: "Quick Chat"))

    # The populated list at the narrowest supported viewport. Asserting on the
    # row keeps this honest: an empty list would fit trivially.
    session
    |> resize_to_mobile()
    |> visit("/dashboard/meeting-settings")
    |> wait_for_live()
    |> assert_has(css("h3", text: "Quick Chat"))
    |> assert_no_horizontal_overflow("meeting settings at 320px")
  end
end
