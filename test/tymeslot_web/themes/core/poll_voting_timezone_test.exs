defmodule TymeslotWeb.Themes.Core.PollVotingTimezoneTest do
  @moduledoc """
  A voter who asks for a link on the public poll page is stored with the
  timezone their browser reports, which the confirmed meeting's emails use
  when that voter becomes its main participant.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :polls

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo

  setup %{conn: conn} do
    %{user: user, profile: profile} = seed_booking_account("1", "timezone-host", "Etc/UTC")
    poll = insert(:poll, user: user, timezone: "Etc/UTC")
    insert(:poll_time_slot, poll: poll)
    %{conn: conn, poll: poll, profile: profile}
  end

  defp request_link(conn, ctx, browser_timezone) do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"timezone" => browser_timezone})
      |> live("/#{ctx.profile.username}/poll/#{ctx.poll.token}")

    view
    |> form("form[data-testid='poll-register-form']", %{
      "name" => "Grace Hopper",
      "email" => "grace@example.com"
    })
    |> render_submit()

    assert has_element?(view, "[data-testid='poll-link-sent']")
    Repo.get_by!(PollParticipantSchema, poll_id: ctx.poll.id, email: "grace@example.com")
  end

  test "stores the timezone the voter's browser reports", %{conn: conn} = ctx do
    assert request_link(conn, ctx, "America/Chicago").timezone == "America/Chicago"
  end

  test "stores no timezone when the browser reports one that does not exist",
       %{conn: conn} = ctx do
    assert request_link(conn, ctx, "Mars/Olympus_Mons").timezone == nil
  end
end
