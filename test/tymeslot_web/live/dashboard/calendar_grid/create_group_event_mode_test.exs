defmodule TymeslotWeb.Dashboard.CalendarGrid.CreateGroupEventModeTest do
  @moduledoc """
  Covers Quick Add's group-event mode: a one-off event people sign up for,
  created from the grid through the dialog's own controls, and how it then
  shows on the meeting settings page.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.OneOffEvents
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  defmodule DenyGroupBookingsChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :group_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  setup %{conn: conn} do
    TestMocks.setup_all_mocks()
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "trainer", timezone: "Etc/UTC")
    venue = insert(:venue, user: user, name: "Main Hall")
    # People book a group event on the public page, which needs a calendar.
    insert(:calendar_integration, user: user, is_active: true)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, venue: venue}
  end

  defp event_date, do: Date.add(Date.utc_today(), 10)

  defp open_group_event_form(lv, end_minute \\ "30") do
    lv
    |> element("#calendar-grid")
    |> render_hook("show_create_form", %{
      "date" => Date.to_iso8601(event_date()),
      "start-hour" => "18",
      "start-minute" => "0",
      "end-hour" => "19",
      "end-minute" => end_minute
    })

    lv |> element(~s{[data-testid="create-mode-group-event"]}) |> render_click()
  end

  defp fill_in(lv, title, fields) do
    lv |> element("#create-event-title") |> render_blur(%{"value" => title})
    lv |> form("#create-group-event-form", group_event: fields) |> render_change()
  end

  defp save(lv) do
    lv |> element(~s{#create-event-modal button[phx-click="save_event"]}) |> render_click()
    # The flash travels through the parent LiveView; render again to see it.
    render(lv)
  end

  test "offers the mode and asks for its details", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")

    html = open_group_event_form(lv)

    assert html =~ "New Group Event"
    assert html =~ ~s(id="create-group-event-form")
    assert html =~ "Main Hall"
    refute html =~ ~s(id="create-meeting-guest-name")
    refute html =~ ~s(id="create-event-all-day")
  end

  test "is not offered without a calendar people can book through", %{conn: conn} do
    Repo.delete_all(CalendarIntegrationSchema)
    {:ok, lv, _html} = live(conn, ~p"/dashboard")

    html = lv |> element("#calendar-grid") |> render_hook("show_create_form", %{})

    assert html =~ "New Meeting"
    refute html =~ ~s(data-testid="create-mode-group-event")
    # Meeting is the only kind left, so there is no toggle offering one option.
    refute has_element?(lv, "#create-event-modal #create-mode")

    # A stale or forged switch to the mode changes nothing.
    html =
      lv
      |> element("#calendar-grid")
      |> render_hook("set_create_mode", %{"mode" => "group_event"})

    refute html =~ ~s(id="create-group-event-form")
  end

  test "is not offered when group bookings are not allowed", %{conn: conn} do
    assigns = Application.get_env(:tymeslot, :feature_assigns, [])

    setup_config(:tymeslot,
      feature_access_checker: DenyGroupBookingsChecker,
      feature_assigns: Keyword.put(assigns, :group_bookings_allowed, false)
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard")

    html = lv |> element("#calendar-grid") |> render_hook("show_create_form", %{})

    refute html =~ ~s(data-testid="create-mode-group-event")
  end

  test "creates the event with its session and shows its booking link", %{
    conn: conn,
    user: user,
    venue: venue
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")
    open_group_event_form(lv)

    fill_in(lv, "Introduction to X", %{
      "max_participants" => "12",
      "location" => "venue:#{venue.id}",
      "closes_at" => "#{Date.to_iso8601(Date.add(event_date(), -1))}T12:00",
      "description" => "Bring a laptop."
    })

    html = save(lv)

    refute html =~ ~s(id="create-event-modal")
    assert html =~ "Event created. Its booking link:"
    assert html =~ "/trainer/introduction-to-x"

    assert [type] = Repo.all(MeetingTypeSchema)
    assert type.user_id == user.id
    assert OneOffEvents.one_off?(type)
    assert type.max_participants == 12
    assert type.duration_minutes == 90
    assert type.description == "Bring a laptop."

    assert [session] = PlannedSessions.list(type)
    assert session.start_time == DateTime.new!(event_date(), ~T[18:00:00], "Etc/UTC")

    assert session.registration_closes_at ==
             DateTime.new!(Date.add(event_date(), -1), ~T[12:00:00], "Etc/UTC")
  end

  test "keeps the dialog open and says what is missing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")
    open_group_event_form(lv)

    fill_in(lv, "Introduction to X", %{"max_participants" => "12", "location" => ""})
    html = save(lv)

    assert html =~ "Choose where the event takes place."
    assert html =~ ~s(id="create-event-modal")
    assert Repo.all(MeetingTypeSchema) == []
  end

  test "refuses a registration close after the start", %{conn: conn, venue: venue} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")
    open_group_event_form(lv)

    fill_in(lv, "Introduction to X", %{
      "max_participants" => "12",
      "location" => "venue:#{venue.id}",
      "closes_at" => "#{Date.to_iso8601(Date.add(event_date(), 1))}T12:00"
    })

    assert save(lv) =~
             "Registration has to close in the future, and no later than the event starts."

    assert Repo.all(MeetingTypeSchema) == []
  end

  test "says why an over-long title is refused", %{conn: conn, venue: venue} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")
    open_group_event_form(lv)

    fill_in(lv, String.duplicate("a", 120), %{
      "max_participants" => "12",
      "location" => "venue:#{venue.id}"
    })

    assert save(lv) =~ "Meeting name must be 100 characters or less"
    assert Repo.all(MeetingTypeSchema) == []
  end

  test "says why a length off the 5-minute step is refused", %{conn: conn, venue: venue} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")
    open_group_event_form(lv, "37")

    fill_in(lv, "Introduction to X", %{
      "max_participants" => "12",
      "location" => "venue:#{venue.id}"
    })

    assert save(lv) =~ "An event lasts a multiple of 5 minutes."
    assert Repo.all(MeetingTypeSchema) == []
  end

  test "stores the description sanitised, as the meeting-type form does", %{
    conn: conn,
    venue: venue
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")
    open_group_event_form(lv)

    fill_in(lv, "Introduction to X", %{
      "max_participants" => "12",
      "location" => "venue:#{venue.id}",
      "description" => "Bring a\u0000 laptop."
    })

    save(lv)

    assert [%{description: description}] = Repo.all(MeetingTypeSchema)
    refute description =~ "\u0000"
    assert description =~ "laptop."
  end

  describe "on the meeting settings page" do
    setup %{user: user, venue: venue} do
      starts_at = DateTime.new!(event_date(), ~T[18:00:00], "Etc/UTC")

      {:ok, %{meeting_type: event}} =
        OneOffEvents.create(%{
          user_id: user.id,
          name: "Introduction to X",
          starts_at: starts_at,
          duration_minutes: 90,
          max_participants: 12,
          location: {:venue, venue.id}
        })

      regular = insert(:meeting_type, user: user, name: "Strategy Session")
      %{event: event, regular: regular}
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

      [row] =
        html |> Floki.parse_document!() |> Floki.find(~s{[data-testid="event-row"]})

      # Laid out as a meeting type card: the name as the card's title.
      assert [title] = Floki.find(row, "h2")
      assert Floki.text(title) =~ "Introduction to X"
      assert Floki.text(row) =~ "Registration open"
      assert Floki.text(row) =~ "0/12 seats taken"

      assert [link] = Floki.attribute(row, "#copy-event-link-#{event.id}", "data-copy-text")
      assert link =~ "/trainer/introduction-to-x"
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
end
