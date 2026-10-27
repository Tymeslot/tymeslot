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
  alias Tymeslot.Bookings.MeetingLinks

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  # Every organiser-facing message about a booking (the external-change
  # email, Slack, Telegram, webhook payloads) links to it with
  # `MeetingLinks.host_view_url/1`. That link has to open, and show the
  # booking it names. It names it by id: the uid is the booker's capability
  # and must not travel in messages to the host.
  describe "the link to one booking" do
    test "opens the dashboard on that booking alone", %{conn: conn, user: user} do
      now = DateTime.utc_now()

      target =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Linked Booking",
          start_time: DateTime.add(now, 2, :day),
          end_time: DateTime.add(now, 2 * 24 * 60 + 30, :minute)
        )

      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Other Booking",
        start_time: DateTime.add(now, 1, :day),
        end_time: DateTime.add(now, 24 * 60 + 30, :minute)
      )

      link = MeetingLinks.host_view_url(target.id)
      refute link =~ target.uid

      %URI{path: path, query: query} = URI.parse(link)
      assert get(conn, path <> "?" <> query).status == 200

      {:ok, view, _html} = live(conn, path <> "?" <> query)

      html = render(view)
      assert html =~ "Linked Booking"
      refute html =~ "Other Booking"

      view |> element("a", "Show all meetings") |> render_click()
      assert render(view) =~ "Other Booking"
    end

    test "shows nothing of a booking the host does not own", %{conn: conn} do
      stranger = insert(:user)

      theirs =
        insert(:meeting,
          organizer_user_id: stranger.id,
          attendee_name: "Stranger Owned Booking",
          start_time: DateTime.add(DateTime.utc_now(), 1, :day),
          end_time: DateTime.add(DateTime.utc_now(), 24 * 60 + 30, :minute)
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings?meeting=#{theirs.id}")

      html = render(view)
      refute html =~ "Stranger Owned Booking"
      assert html =~ "This booking isn&#39;t available."
      refute html =~ "Showing one booking."
    end

    test "says a malformed link names no booking rather than showing them all",
         %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Unrelated Booking",
        start_time: DateTime.add(DateTime.utc_now(), 1, :day),
        end_time: DateTime.add(DateTime.utc_now(), 24 * 60 + 30, :minute)
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings?meeting=not-a-booking")

      html = render(view)
      assert html =~ "This booking isn&#39;t available."
      refute html =~ "Unrelated Booking"
    end

    # The param is user-controlled: Plug parses `?meeting[x]=1` into a map and
    # `?meeting[]=a` into a list, neither of which names a booking.
    for {label, query} <- [
          {"empty", "meeting="},
          {"a map", "meeting[x]=1"},
          {"a list", "meeting[]=a"}
        ] do
      test "shows the normal list when the meeting param is #{label}",
           %{conn: conn, user: user} do
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Listed Booking",
          start_time: DateTime.add(DateTime.utc_now(), 1, :day),
          end_time: DateTime.add(DateTime.utc_now(), 24 * 60 + 30, :minute)
        )

        {:ok, view, _html} = live(conn, "/dashboard/meetings?" <> unquote(query))

        html = render(view)
        assert html =~ "Listed Booking"
        refute html =~ "This booking isn&#39;t available."
      end
    end

    test "marks no tab as current while it shows a past booking", %{conn: conn, user: user} do
      past =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Last Week Booking",
          start_time: DateTime.add(DateTime.utc_now(), -7, :day),
          end_time: DateTime.add(DateTime.utc_now(), -7 * 24 * 60 + 30, :minute)
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings?meeting=#{past.id}")

      assert render(view) =~ "Last Week Booking"
      refute has_element?(view, ~s(#meetings-filter button[aria-pressed="true"]))

      view |> element("#meetings-filter-past") |> render_click()
      assert has_element?(view, ~s(#meetings-filter-past[aria-pressed="true"]))
    end
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
