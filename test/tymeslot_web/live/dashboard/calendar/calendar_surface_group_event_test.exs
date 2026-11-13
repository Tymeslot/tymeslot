defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceGroupEventTest do
  @moduledoc """
  "Group event" in the side panel's New event state: offered on a draft
  without guests to an organiser whose plan includes group bookings, it
  turns the draft into a one-off event people sign up for
  (`Tymeslot.MeetingTypes.OneOffEvents`), with its participant limit,
  place and registration close, and shows the event's booking link once it
  is created.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.OneOffEvents
  alias Tymeslot.Profiles.ProfileSchema
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
    context = owner(conn, timezone: "Etc/UTC")
    TestMocks.setup_all_mocks()

    ProfileSchema
    |> Repo.get_by!(user_id: context.user.id)
    |> Changeset.change(username: "trainer")
    |> Repo.update!()

    venue = insert(:venue, user: context.user, name: "Main Hall")
    Map.put(context, :venue, venue)
  end

  defp more_options(lv, integration, extra) do
    lv
    |> element("#calendar-canvas")
    |> render_hook(
      "calendar:more_options",
      Map.merge(
        %{
          "draft" => "d1",
          "title" => "Introduction to X",
          "start" => "2026-10-24T18:00",
          "end" => "2026-10-24T19:30",
          "all_day" => false,
          "calendar" => "#{integration.id}:work",
          "location" => "",
          "guests" => [],
          "free" => false
        },
        extra
      )
    )

    assert_reply(lv, %{opened: true})
  end

  defp new_form(lv), do: form(lv, "#calendar-panel-new-form")

  defp as_group_event(lv, fields \\ %{}),
    do: render_change(new_form(lv), Map.merge(%{"group_event" => "true"}, fields))

  defp create(lv, fields) do
    render_submit(new_form(lv), Map.merge(%{"intent" => "create"}, fields))
    # The flash travels through the parent LiveView; render again to see it.
    render(lv)
  end

  defp open(conn, integration, extra \\ %{}) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration, extra)
    lv
  end

  test "is offered on a draft without guests and asks for its details in place of what it cannot use",
       %{conn: conn, integration: integration} do
    lv = open(conn, integration)

    assert has_element?(lv, "#calendar-panel-group-event", "Group event")
    refute has_element?(lv, "#calendar-panel-group-event-fields")

    as_group_event(lv)

    assert has_element?(lv, "#calendar-panel-group-event-fields")
    assert has_element?(lv, "#calendar-panel-group-event-location option", "Main Hall")
    refute has_element?(lv, "#calendar-panel-new-all-day")
    refute has_element?(lv, "#calendar-panel-new-free")
    refute has_element?(lv, "#calendar-panel-new-location")
    refute has_element?(lv, "#calendar-panel-meeting")
  end

  test "is not offered on a draft with guests", %{conn: conn, integration: integration} do
    lv = open(conn, integration, %{"guests" => ["ada@example.com"]})

    refute has_element?(lv, "#calendar-panel-group-event")
  end

  # People book a group event on the public page, which needs a calendar.
  test "is not offered without a calendar people can book through", %{
    conn: conn,
    integration: integration
  } do
    Repo.delete_all(CalendarIntegrationSchema)
    lv = open(conn, integration, %{"calendar" => ""})

    assert has_element?(lv, "#calendar-panel-new-form")
    refute has_element?(lv, "#calendar-panel-group-event")
  end

  test "is not offered when group bookings are not allowed", %{
    conn: conn,
    integration: integration
  } do
    assigns = Application.get_env(:tymeslot, :feature_assigns, [])

    setup_config(:tymeslot,
      feature_access_checker: DenyGroupBookingsChecker,
      feature_assigns: Keyword.put(assigns, :group_bookings_allowed, false)
    )

    lv = open(conn, integration)

    refute has_element?(lv, "#calendar-panel-group-event")

    # A forged tick creates a plain event, never a group one.
    render_change(new_form(lv), %{"group_event" => "true"})
    refute has_element?(lv, "#calendar-panel-group-event-fields")
  end

  test "creates the event with its session and shows its booking link", %{
    conn: conn,
    user: user,
    integration: integration,
    venue: venue
  } do
    lv = open(conn, integration)

    as_group_event(lv)

    html =
      create(lv, %{
        "max_participants" => "12",
        "group_location" => "venue:#{venue.id}",
        "closes_at" => "2026-10-23T12:00",
        "description" => "Bring a laptop."
      })

    refute has_element?(lv, "#calendar-panel-new-form")
    assert html =~ "Event created. Its booking link:"
    assert html =~ "/trainer/introduction-to-x"

    assert [type] = Repo.all(MeetingTypeSchema)
    assert type.user_id == user.id
    assert OneOffEvents.one_off?(type)
    assert type.max_participants == 12
    assert type.duration_minutes == 90
    assert type.description == "Bring a laptop."

    assert [session] = PlannedSessions.list(type)
    assert session.start_time == ~U[2026-10-24 18:00:00Z]
    assert session.registration_closes_at == ~U[2026-10-23 12:00:00Z]
  end

  test "keeps the panel open and says what is missing", %{conn: conn, integration: integration} do
    lv = open(conn, integration)
    as_group_event(lv)

    create(lv, %{"max_participants" => "12", "group_location" => ""})

    assert has_element?(lv, "#calendar-panel-new-form")
    assert render(lv) =~ "Choose where the event takes place."
    assert Repo.all(MeetingTypeSchema) == []
  end

  test "asks for a title", %{conn: conn, integration: integration, venue: venue} do
    lv = open(conn, integration, %{"title" => ""})
    as_group_event(lv)

    create(lv, %{"max_participants" => "12", "group_location" => "venue:#{venue.id}"})

    assert render(lv) =~ "Give the event a title."
    assert Repo.all(MeetingTypeSchema) == []
  end

  test "refuses a registration close after the start", %{
    conn: conn,
    integration: integration,
    venue: venue
  } do
    lv = open(conn, integration)
    as_group_event(lv)

    create(lv, %{
      "max_participants" => "12",
      "group_location" => "venue:#{venue.id}",
      "closes_at" => "2026-10-25T12:00"
    })

    assert render(lv) =~
             "Registration has to close in the future, and no later than the event starts."

    assert Repo.all(MeetingTypeSchema) == []
  end

  test "says why a participant limit out of range is refused", %{
    conn: conn,
    integration: integration,
    venue: venue
  } do
    lv = open(conn, integration)
    as_group_event(lv)

    create(lv, %{"max_participants" => "1", "group_location" => "venue:#{venue.id}"})

    assert render(lv) =~ "Allow between 2 and"
    assert Repo.all(MeetingTypeSchema) == []
  end

  test "says why a length off the 5-minute step is refused", %{
    conn: conn,
    integration: integration,
    venue: venue
  } do
    lv = open(conn, integration, %{"end" => "2026-10-24T19:37"})
    as_group_event(lv)

    create(lv, %{"max_participants" => "12", "group_location" => "venue:#{venue.id}"})

    assert render(lv) =~ "An event lasts a multiple of 5 minutes."
    assert Repo.all(MeetingTypeSchema) == []
  end

  test "stores the description sanitised, as the meeting-type form does", %{
    conn: conn,
    integration: integration,
    venue: venue
  } do
    lv = open(conn, integration)
    as_group_event(lv)

    create(lv, %{
      "max_participants" => "12",
      "group_location" => "venue:#{venue.id}",
      "description" => "Bring a\u0000 laptop."
    })

    assert [%{description: description}] = Repo.all(MeetingTypeSchema)
    refute description =~ "\u0000"
    assert description =~ "laptop."
  end
end
