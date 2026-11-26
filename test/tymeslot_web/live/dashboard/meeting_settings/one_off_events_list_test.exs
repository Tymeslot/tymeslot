defmodule TymeslotWeb.Dashboard.MeetingSettings.OneOffEventsListTest do
  @moduledoc """
  One-off group events (`Tymeslot.MeetingTypes.OneOffEvents`) on the meeting
  settings page: listed apart from the meeting types with their seats and
  booking link, deleted with their session cancelled and everyone who
  signed up told, and shown without a link once cancelled.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.OneOffEvents
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_all_mocks()
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "trainer", timezone: "Etc/UTC")
    venue = insert(:venue, user: user, name: "Main Hall")
    # People book a group event on the public page, which needs a calendar.
    insert(:calendar_integration, user: user, is_active: true)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    starts_at = DateTime.new!(Date.add(Date.utc_today(), 10), ~T[18:00:00], "Etc/UTC")

    {:ok, %{meeting_type: event}} =
      OneOffEvents.create(%{
        user_id: user.id,
        name: "Introduction to X",
        starts_at: starts_at,
        duration_minutes: 90,
        max_participants: 12,
        location: {:venue, venue.id}
      })

    insert(:meeting_type, user: user, name: "Strategy Session")
    {:ok, conn: conn, user: user, event: event}
  end

  test "lists the event apart from the meeting types, with its seats and link", %{
    conn: conn,
    event: event
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/meeting-settings")
    html = render(lv)

    sortable = html |> Floki.parse_document!() |> Floki.find("#meeting-types-sortable-list")
    assert Floki.text(sortable) =~ "Strategy Session"
    refute Floki.text(sortable) =~ "Introduction to X"

    [row] = html |> Floki.parse_document!() |> Floki.find(~s{[data-testid="event-row"]})

    # Laid out as a meeting type card: the name as the card's title.
    assert [title] = Floki.find(row, "h2")
    assert Floki.text(title) =~ "Introduction to X"
    assert Floki.text(row) =~ "Registration open"
    assert Floki.text(row) =~ "0/12 seats taken"

    assert [link] = Floki.attribute(row, "#copy-event-link-#{event.id}", "data-copy-text")
    assert link =~ "/trainer/introduction-to-x"
  end

  test "counts the people signed up, not the seats held for bookers still paying", %{
    conn: conn,
    event: event
  } do
    [session] = PlannedSessions.list(event)
    insert(:participant, meeting: session, email: "ada@example.com")
    insert(:seat_hold, meeting: session, seats: 2, email: "paying@example.com")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/meeting-settings")

    [row] =
      lv |> render() |> Floki.parse_document!() |> Floki.find(~s{[data-testid="event-row"]})

    assert Floki.text(row) =~ "1/12 seats taken"
  end

  test "deleting the event cancels its session and tells who signed up", %{
    conn: conn,
    event: event
  } do
    [session] = PlannedSessions.list(event)
    insert(:participant, meeting: session, email: "ada@example.com")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/meeting-settings")

    lv
    |> element("[phx-click='show_delete_modal'][phx-value-id='#{event.id}']")
    |> render_click()

    assert render(lv) =~ "The 1 person who signed up is told by email."

    lv
    |> element("#delete-meeting-type-modal button", "Delete Meeting Type")
    |> render_click()

    assert Repo.get(MeetingTypeSchema, event.id) == nil
    assert Repo.get!(MeetingSchema, session.id).status == :cancelled
  end

  test "shows a cancelled event without its link", %{conn: conn, event: event, user: user} do
    [session] = PlannedSessions.list(event)
    {:ok, _cancelled} = PlannedSessions.cancel(session, user.id)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/meeting-settings")

    [row] =
      lv |> render() |> Floki.parse_document!() |> Floki.find(~s{[data-testid="event-row"]})

    assert Floki.text(row) =~ "Cancelled"
    assert Floki.find(row, "#copy-event-link-#{event.id}") == []
  end
end
