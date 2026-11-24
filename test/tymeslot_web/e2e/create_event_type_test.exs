defmodule TymeslotWeb.E2E.CreateEventTypeTest do
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :meeting_types

  test "user can create a meeting type from the dashboard", %{session: session} do
    {session, _user} = log_in(session)

    session =
      session
      |> visit("/dashboard/meeting-settings")
      |> click(filter(by_css("button"), has_text: "Add Meeting Type"))
      |> fill(by_css("input[name='meeting_type[name]']"), "Quick Chat")
      |> fill(by_css("input[name='meeting_type[duration]']"), "30")
      |> click(filter(by_css("button[type='submit']"), has_text: "Create meeting type"))
      # Creating switches the same form to editing the new type.
      |> assert_has(filter(by_css("[aria-live='polite']"), has_text: "All changes saved"))
      |> click(filter(by_css("button"), has_text: "Done"))

    # Should see the new type in the list (name is in an h2)
    session = assert_has(session, filter(by_css("h2"), has_text: "Quick Chat"))

    # The populated list at the narrowest supported viewport. Asserting on the
    # row keeps this honest: an empty list would fit trivially.
    session
    |> resize_to_mobile()
    |> visit("/dashboard/meeting-settings")
    |> assert_has(filter(by_css("h2"), has_text: "Quick Chat"))
    |> assert_no_horizontal_overflow("meeting settings at 320px")
  end
end
