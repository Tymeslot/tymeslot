defmodule TymeslotWeb.Dashboard.PollEditorLeaveTest do
  @moduledoc """
  Following a link away from an open poll's editor with changes unsaved asks
  first, since saving can email everyone on the poll: the host either leaves
  without saving, and the held link goes, or keeps editing what was typed.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.PollDashboardHelpers

  alias Tymeslot.Polls
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "leavehost", timezone: "Etc/UTC")
    insert(:calendar_integration, user: user, is_active: true)

    deadline = DateTime.add(DateTime.utc_now(:second), 3, :day)

    poll =
      insert(:poll,
        user: user,
        status: :open,
        title: "Offsite",
        timezone: "Etc/UTC",
        meeting_type_id: nil,
        deadline_at: deadline
      )

    insert(:poll_time_slot, poll: poll, start_time: DateTime.add(deadline, 4, :day))

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()

    await_slot_health(view)
    view |> element("[data-testid='poll-edit-details']") |> render_click()

    view
    |> form("[data-testid='poll-details-form']", %{"poll" => %{"title" => "Team offsite"}})
    |> render_change()

    {:ok, view: view, poll: poll, user: user}
  end

  # What the editor's `UnsavedChanges` hook does when a link elsewhere is
  # clicked with changes typed: the `leave` event, to the target it names.
  defp follow_link_away(view) do
    editor = "[data-testid='poll-editor'][phx-hook='UnsavedChanges'][data-leave-event='leave']"

    [target] =
      view
      |> element(editor)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-leave-target")

    view |> with_target("[data-phx-component='#{target}']") |> render_hook("leave", %{})
  end

  test "asks first, and leaving without saving lets the link go", %{
    view: view,
    poll: poll,
    user: user
  } do
    follow_link_away(view)

    assert has_element?(view, "[data-testid='confirm-leave-poll-editor']")
    refute_push_event(view, "unsaved:proceed", %{})

    view |> element("[data-testid='confirm-leave-poll-editor']") |> render_click()

    assert_push_event(view, "unsaved:proceed", %{})
    refute has_element?(view, "[data-testid='confirm-leave-poll-editor']")
    assert {:ok, %{title: "Offsite"}} = Polls.get_poll_for_host(poll.id, user.id)
  end

  test "keeping on editing holds the link and keeps what was typed", %{view: view} do
    follow_link_away(view)

    view |> element("#leave-poll-editor-cancel") |> render_click()

    refute has_element?(view, "[data-testid='confirm-leave-poll-editor']")
    refute_push_event(view, "unsaved:proceed", %{})
    assert has_element?(view, "[data-testid='poll-details-form'] input[value='Team offsite']")
  end
end
