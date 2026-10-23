defmodule TymeslotWeb.Themes.Core.PollVotingNewTimesTest do
  @moduledoc """
  Which times the public voting page labels as new to a returning voter.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils
  @moduletag :polls

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  defp poll_path(username, token), do: "/#{username}/poll/#{token}"

  setup %{conn: conn} do
    %{user: user, profile: profile} = seed_booking_account("1", "new-times-host", "Etc/UTC")
    poll = insert(:poll, user: user, title: "Pick a time")
    slot = insert(:poll_time_slot, poll: poll)
    %{conn: conn, poll: poll, slot: slot, profile: profile}
  end

  test "marks a time added after someone voted as new to them, and only to them", %{
    conn: conn,
    poll: poll,
    slot: slot,
    profile: profile
  } do
    now = DateTime.utc_now(:second)

    # There when they voted, and left unanswered: skipped, not new.
    _skipped =
      insert(:poll_time_slot,
        poll: poll,
        start_time: DateTime.add(slot.start_time, 2, :day),
        end_time: DateTime.add(slot.end_time, 2, :day),
        inserted_at: DateTime.add(now, -2, :hour)
      )

    added =
      insert(:poll_time_slot,
        poll: poll,
        start_time: DateTime.add(slot.start_time, 1, :day),
        end_time: DateTime.add(slot.end_time, 1, :day)
      )

    voted = insert(:poll_participant, poll: poll, voted_at: DateTime.add(now, -1, :hour))
    insert(:poll_vote, participant: voted, time_slot: slot, response: :yes)
    not_yet = insert(:poll_participant, poll: poll)

    {:ok, view, _html} =
      live(conn, poll_path(profile.username, poll.token) <> "?p=#{voted.token}")

    rows =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[data-testid='poll-slot']")

    {added_rows, other_rows} =
      Enum.split_with(rows, &(Floki.find(&1, "input[data-testid='vote-#{added.id}-yes']") != []))

    # The badge sits on the added time's row and on no other.
    assert [added_row] = added_rows
    assert [_badge] = Floki.find(added_row, "[data-testid='poll-slot-new']")
    assert other_rows != []
    assert Enum.all?(other_rows, &(Floki.find(&1, "[data-testid='poll-slot-new']") == []))

    assert has_element?(view, "input[data-testid='vote-#{added.id}-yes']")

    {:ok, fresh, _html} =
      live(conn, poll_path(profile.username, poll.token) <> "?p=#{not_yet.token}")

    refute has_element?(fresh, "[data-testid='poll-slot-new']")
  end
end
