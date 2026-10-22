defmodule TymeslotWeb.Themes.Core.PollVotingDeadlineTest do
  @moduledoc """
  A voter with the voting page open when the poll's deadline passes sees
  voting end there and then, without a reload, unless the host has moved the
  deadline later in the meantime.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :polls

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.Test.ClockHelpers, only: [freeze_clock: 1]

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Repo
  alias TymeslotWeb.ThemeTestMatrix

  @vote_form "form[data-testid='poll-vote-form']"

  defp open_personal_page(conn, theme_id, username) do
    %{user: user, profile: profile} = seed_booking_account(theme_id, username, "Etc/UTC")
    deadline = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
    poll = insert(:poll, user: user, deadline_at: deadline)
    insert(:poll_time_slot, poll: poll)
    voter = insert(:poll_participant, poll: poll, confirmed_at: DateTime.utc_now(:second))

    {:ok, view, _html} = live(conn, "/#{profile.username}/poll/#{poll.token}?p=#{voter.token}")
    assert has_element?(view, @vote_form)

    %{view: view, poll: poll, deadline: deadline}
  end

  test "an open page arms a timer for the poll's deadline", %{conn: conn} do
    %{view: view, deadline: deadline} = open_personal_page(conn, "1", "armed-timer-host")

    assert %{ref: ref, deadline: ^deadline} =
             :sys.get_state(view.pid).socket.assigns.deadline_timer

    expected_ms = DateTime.diff(deadline, DateTime.utc_now(), :millisecond)
    assert_in_delta Process.read_timer(ref), expected_ms, 2_000
  end

  for theme <- ThemeTestMatrix.all() do
    test "the vote form gives way to voting ended at the deadline in the #{theme.slug} theme",
         %{conn: conn} do
      %{view: view, poll: poll, deadline: deadline} =
        open_personal_page(conn, unquote(theme.id), "closing-#{unquote(theme.slug)}")

      # The LiveView reads the clock this test freezes; the message is what
      # the page's own deadline timer sends.
      freeze_clock(DateTime.add(deadline, 1, :second))
      send(view.pid, {:poll_deadline_reached, poll.id})

      assert has_element?(view, "[data-testid='poll-voting-ended']")
      refute has_element?(view, @vote_form)
    end
  end

  test "a deadline the host moved later keeps the vote form past the old one", %{conn: conn} do
    %{view: view, poll: poll, deadline: deadline} =
      open_personal_page(conn, "1", "moved-deadline-host")

    # Moved without a broadcast, so only the reload on waking can see it.
    poll |> Changeset.change(deadline_at: ~U[2099-01-15 10:00:00Z]) |> Repo.update!()

    freeze_clock(DateTime.add(deadline, 1, :second))
    send(view.pid, {:poll_deadline_reached, poll.id})

    assert has_element?(view, @vote_form)
    refute has_element?(view, "[data-testid='poll-voting-ended']")
    assert has_element?(view, "[data-testid='poll-deadline']", "15 January 2099")
  end

  test "a timer message for another poll changes nothing", %{conn: conn} do
    %{view: view, deadline: deadline} = open_personal_page(conn, "1", "other-poll-host")

    freeze_clock(DateTime.add(deadline, 1, :second))
    send(view.pid, {:poll_deadline_reached, UUID.generate()})

    assert has_element?(view, @vote_form)
  end
end
