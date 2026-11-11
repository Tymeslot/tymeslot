defmodule TymeslotWeb.Themes.Core.PollVotingLocationTest do
  @moduledoc """
  The public voting page names where the meeting will be held, so a visitor
  can tell before answering whether they could come at all.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :polls

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Polls

  setup do
    %{user: user, profile: profile} = seed_booking_account("1", "place-host", "Etc/UTC")
    %{user: user, profile: profile}
  end

  defp open(conn, profile, poll) do
    insert(:poll_time_slot, poll: poll)
    {:ok, view, _html} = live(conn, "/#{profile.username}/poll/#{poll.token}")
    view
  end

  test "names the place the host typed in", %{conn: conn, user: user, profile: profile} do
    poll = insert(:poll, user: user, location_kind: :custom, location_details: "Garden pavilion")

    assert conn
           |> open(profile, poll)
           |> has_element?("[data-testid='poll-location']", "Garden pavilion")
  end

  test "says a video call's link comes once a time is confirmed",
       %{conn: conn, user: user, profile: profile} do
    video = insert(:video_integration, user: user, is_active: true)
    poll = insert(:poll, user: user, location_kind: :video, video_integration_id: video.id)

    assert conn
           |> open(profile, poll)
           |> has_element?(
             "[data-testid='poll-location']",
             "The link follows once a time is confirmed"
           )
  end

  test "names nothing when the poll has no location", %{conn: conn, user: user, profile: profile} do
    poll = insert(:poll, user: user)
    refute conn |> open(profile, poll) |> has_element?("[data-testid='poll-location']")
  end

  test "shows a location the host sets while the page is open",
       %{conn: conn, user: user, profile: profile} do
    poll = insert(:poll, user: user)
    view = open(conn, profile, poll)
    refute has_element?(view, "[data-testid='poll-location']")

    {:ok, _poll} =
      Polls.update_details(poll.id, user.id, %{
        "location_kind" => :custom,
        "location_details" => "Boathouse"
      })

    assert render(view) =~ "Boathouse"
    assert has_element?(view, "[data-testid='poll-location']", "Boathouse")
  end
end
