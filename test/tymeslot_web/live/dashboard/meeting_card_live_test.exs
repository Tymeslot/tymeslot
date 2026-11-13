defmodule TymeslotWeb.Dashboard.MeetingCardLiveTest do
  @moduledoc """
  Covers what a booking card on the Meetings page tells the organiser: which
  meeting type was booked, where it takes place, and a time range that reads
  on one line per end.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meetings
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  test "names the meeting type on the booking card", %{conn: conn, user: user} do
    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      attendee_name: "John Doe",
      meeting_type: "Discovery call"
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    assert has_element?(view, ~s([data-testid="meeting-type"]), "Discovery call")
  end

  test "shows where the meeting takes place, and no location tile without one", %{
    conn: conn,
    user: user
  } do
    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      title: "Board dinner",
      location: "The Old Mill, Main Street 1",
      location_kind: :custom
    )

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      title: "Video sync",
      location: "Video call",
      location_kind: :video,
      start_time: DateTime.add(DateTime.utc_now(), 3, :day),
      end_time: DateTime.add(DateTime.utc_now(), 3 * 24 * 60 + 30, :minute)
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    assert has_element?(
             view,
             ~s([data-testid="meeting-location"]),
             "The Old Mill, Main Street 1"
           )

    assert [_one] =
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find(~s([data-testid="meeting-location"]))
  end

  test "shows a default location label in the dashboard's language", %{conn: conn, user: user} do
    user |> Changeset.change(locale: "de") |> Repo.update!()

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      location: "In person",
      location_kind: :in_person
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    assert has_element?(view, ~s([data-testid="meeting-location"]), "Vor Ort")
  end

  # Meetings booked before `location_kind` existed carry English placeholders
  # older releases wrote, or the video link, in their location.
  test "shows a legacy meeting's placeholder location translated, or not at all", %{conn: conn} do
    host = insert(:user, onboarding_completed_at: DateTime.utc_now(), locale: "de")
    insert(:profile, user: host, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(host)

    for {location, days, extra} <- [
          {"In Person", 1, []},
          {"Phone Call", 2, []},
          {"To be determined", 3, []},
          {"https://meet.example.com/abc", 4, [meeting_url: "https://meet.example.com/abc"]}
        ] do
      start = DateTime.add(DateTime.utc_now(), days, :day)

      insert(
        :meeting,
        [
          organizer_user: host,
          organizer_email: host.email,
          location: location,
          location_kind: nil,
          start_time: start,
          end_time: DateTime.add(start, 30, :minute)
        ] ++ extra
      )
    end

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    tiles =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find(~s([data-testid="meeting-location"]))
      |> Enum.map(&(&1 |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()))

    assert length(tiles) == 2
    assert Enum.any?(tiles, &String.ends_with?(&1, "Vor Ort"))
    assert Enum.any?(tiles, &String.ends_with?(&1, "Telefonanruf"))
  end

  test "keeps each end of the booking's time range on one line", %{conn: conn, user: user} do
    start = DateTime.new!(Date.add(Date.utc_today(), 3), ~T[11:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      start_time: start,
      end_time: DateTime.add(start, 15 * 60, :second)
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    # Non-breaking spaces inside each time and before the dash: the card used
    # to wrap as "11:00 AM - 11:15 / AM".
    assert render(view) =~ "11:00\u00A0AM\u00A0– 11:15\u00A0AM"
  end
end
