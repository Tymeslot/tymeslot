defmodule TymeslotWeb.Dashboard.BookingsManagementListTest do
  @moduledoc """
  What the meetings list links to and how it pages: the Join link on a booking
  card, and "Load more" carrying the upcoming list on in order.
  """

  use TymeslotWeb.LiveCase, async: true
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "Meetings list" do
    test "joins with the organiser's own room link where the provider issued one",
         %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Host Link Meeting",
        meeting_url: "https://video.example.com/room-1",
        organizer_video_url: "https://video.example.com/room-1?role=host",
        start_time: DateTime.add(DateTime.utc_now(), -5, :minute),
        end_time: DateTime.add(DateTime.utc_now(), 25, :minute)
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert has_element?(view, ~s(a[href="https://video.example.com/room-1?role=host"]))
      refute has_element?(view, ~s(a[href="https://video.example.com/room-1"]))
    end

    test "Load more continues the upcoming list soonest first", %{conn: conn, user: user} do
      now = DateTime.utc_now()

      # One more page than fits: the dashboard lists 20 meetings at a time.
      for n <- 1..22 do
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Upcoming #{String.pad_leading(to_string(n), 2, "0")}",
          start_time: DateTime.add(now, n, :hour),
          end_time: DateTime.add(now, n * 60 + 30, :minute)
        )
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      html = render(view)
      assert html =~ "Upcoming 20"
      refute html =~ "Upcoming 21"

      view |> element("button", "Load more meetings") |> render_click()

      html = render(view)

      names =
        Regex.scan(~r/Upcoming (\d\d)/, html) |> Enum.map(fn [_match, n] -> n end) |> Enum.dedup()

      expected = Enum.map(1..22, &String.pad_leading(to_string(&1), 2, "0"))

      assert names == expected
      refute has_element?(view, "button", "Load more meetings")
    end
  end
end
