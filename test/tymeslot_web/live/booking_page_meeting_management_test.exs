defmodule TymeslotWeb.BookingPageMeetingManagementTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :scheduling

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.ThemeCustomizations.Presets

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "2")
    page = insert(:booking_page, profile: profile, slug: "einfachiso", booking_theme: "1")
    insert(:theme_customization, profile: profile, theme_id: "2", color_scheme: "ocean")

    insert(:theme_customization,
      profile: profile,
      booking_page: page,
      theme_id: "1",
      color_scheme: "rose"
    )

    start_time = DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.truncate(:second)

    meeting =
      insert(:meeting,
        organizer_user: user,
        status: "confirmed",
        start_time: start_time,
        end_time: DateTime.add(start_time, 1800),
        booking_page_id: page.id
      )

    %{profile: profile, page: page, meeting: meeting}
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  defp primary_colour(view), do: assigns_of(view).theme_tokens.vars["--theme-primary"]

  test "the cancel page of a page's booking wears the page", %{conn: conn, meeting: meeting} do
    {:ok, view, _html} = live(conn, ~p"/joern/meeting/#{meeting.uid}/cancel")

    assert assigns_of(view).theme_id == "1"
    assert primary_colour(view) == Presets.get_color_schemes()["rose"].colors.primary
  end

  test "once the page is gone, the profile's look returns", %{
    conn: conn,
    page: page,
    meeting: meeting
  } do
    {:ok, _deleted} = BookingPages.delete(page)

    {:ok, view, _html} = live(conn, ~p"/joern/meeting/#{meeting.uid}/cancel")

    assert assigns_of(view).theme_id == "2"
    assert primary_colour(view) == Presets.get_color_schemes()["ocean"].colors.primary
  end
end
