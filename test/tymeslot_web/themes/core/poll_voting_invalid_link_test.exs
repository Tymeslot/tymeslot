defmodule TymeslotWeb.Themes.Core.PollVotingInvalidLinkTest do
  @moduledoc """
  A personal voting link whose `?p=` token matches nobody on the poll (a
  mistyped link, or one whose holder was taken off the poll) shows the bare
  link's view with a notice that the link did not work.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :polls

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias TymeslotWeb.ThemeTestMatrix

  defp poll_path(username, token, query \\ ""), do: "/#{username}/poll/#{token}#{query}"

  for theme <- ThemeTestMatrix.all() do
    test "a link matching nobody says so above the bare link in the #{theme.slug} theme",
         %{conn: conn} do
      %{user: user, profile: profile} =
        seed_booking_account(unquote(theme.id), "badlink-#{unquote(theme.slug)}", "Etc/UTC")

      poll = insert(:poll, user: user)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, poll_path(profile.username, poll.token, "?p=garbage"))

      assert has_element?(view, "[data-testid='poll-invalid-link']", "isn't valid")
      assert has_element?(view, "form[data-testid='poll-register-form']")
    end
  end

  test "a working personal link and the bare link show no such notice", %{conn: conn} do
    %{user: user, profile: profile} = seed_booking_account("1", "goodlink-host", "Etc/UTC")
    poll = insert(:poll, user: user)
    insert(:poll_time_slot, poll: poll)
    participant = insert(:poll_participant, poll: poll, confirmed_at: DateTime.utc_now(:second))

    {:ok, bare, _html} = live(conn, poll_path(profile.username, poll.token))
    refute has_element?(bare, "[data-testid='poll-invalid-link']")

    {:ok, personal, _html} =
      live(conn, poll_path(profile.username, poll.token, "?p=#{participant.token}"))

    assert has_element?(personal, "[data-testid='poll-participant-name']")
    refute has_element?(personal, "[data-testid='poll-invalid-link']")
  end
end
