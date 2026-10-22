defmodule TymeslotWeb.Dashboard.PollConfirmErrorsTest do
  @moduledoc """
  What the poll dashboard tells a host when a time they pick cannot be
  confirmed for a reason they can act on, rather than asking them to try
  again.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])
    Gettext.put_locale(TymeslotWeb.Gettext, "en")

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)
    poll = insert(:poll, user: user, status: :open, meeting_type_id: nil)

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    %{conn: conn, user: user, poll: poll}
  end

  defp confirm(conn, poll, slot) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()

    view
    |> element("button[phx-click='request_confirm_slot'][phx-value-slot='#{slot.id}']")
    |> render_click()

    view |> element("#confirm-slot-modal [data-testid='confirm-slot']") |> render_click()
    view
  end

  test "a poll nobody has joined says there is nobody to invite", ctx do
    slot = insert(:poll_time_slot, poll: ctx.poll)

    view = confirm(ctx.conn, ctx.poll, slot)

    assert render(view) =~ "Nobody but you has joined this poll yet"
    refute render(view) =~ "Couldn&#39;t confirm this time"
    assert {:ok, %{status: :open}} = Polls.get_poll_for_host(ctx.poll.id, ctx.user.id)
  end

  test "a time that has passed says so beside the time", ctx do
    start_time = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

    slot =
      insert(:poll_time_slot,
        poll: ctx.poll,
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute)
      )

    insert(:poll_participant, poll: ctx.poll)

    view = confirm(ctx.conn, ctx.poll, slot)

    assert render(view) =~ "This time has already begun."
    refute render(view) =~ "Couldn&#39;t confirm this time"
  end
end
