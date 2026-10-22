defmodule TymeslotWeb.Dashboard.PollConfirmModalTest do
  @moduledoc """
  Confirming a poll's time closes the poll and emails everyone on it, so
  "Confirm this time" asks first: the confirmation names the time, and
  backing out leaves the poll open.
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
    insert(:profile, user: user, username: "confirmhost")

    poll =
      insert(:poll,
        user: user,
        title: "Team offsite",
        status: :open,
        timezone: "Europe/Tallinn",
        meeting_type_id: nil
      )

    # 10:30 UTC on a winter day is 12:30 in Tallinn (EET, UTC+2).
    start_time = ~U[2099-01-15 10:30:00Z]

    slot =
      insert(:poll_time_slot,
        poll: poll,
        start_time: start_time,
        end_time: DateTime.add(start_time, 1, :hour)
      )

    insert(:poll_participant, poll: poll, voted_at: DateTime.utc_now(:second))

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()

    view
    |> element("#poll-slot-#{slot.id} button[phx-click='request_confirm_slot']")
    |> render_click()

    %{view: view, user: user, poll: poll}
  end

  test "names the poll, the time and that everyone is emailed, and confirms nothing yet", ctx do
    modal = ctx.view |> element("#confirm-slot-modal") |> render()

    assert modal =~ "Confirm this time?"
    assert modal =~ "Team offsite"
    assert modal =~ "12:30"
    assert modal =~ "Europe/Tallinn"
    assert modal =~ "Everyone on the poll will be emailed the meeting."
    assert {:ok, %{status: :open}} = Polls.get_poll_for_host(ctx.poll.id, ctx.user.id)
  end

  test "backing out closes the confirmation and leaves the poll open", ctx do
    ctx.view |> element("#confirm-slot-modal button", "Not yet") |> render_click()

    refute has_element?(ctx.view, "#confirm-slot-modal")
    assert {:ok, %{status: :open}} = Polls.get_poll_for_host(ctx.poll.id, ctx.user.id)
  end

  test "confirming settles the poll on that time", ctx do
    ctx.view |> element("#confirm-slot-modal [data-testid='confirm-slot']") |> render_click()

    refute has_element?(ctx.view, "#confirm-slot-modal")
    assert {:ok, %{status: :confirmed}} = Polls.get_poll_for_host(ctx.poll.id, ctx.user.id)
  end
end
