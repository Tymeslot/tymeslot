defmodule TymeslotWeb.Dashboard.CalendarGrid.CreateHostManagedMeetingTest do
  @moduledoc """
  Quick add's meeting mode with its "Main participant" switch turned off: a
  meeting the host manages alone, where everyone invited is a guest who can
  accept or decline and only the host can move or cancel it
  (`Tymeslot.Meetings.HostManaged`). Driven through the modal as the host
  uses it: the switch, the guest form and the title field.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)

    # Without a writable calendar the modal opens straight in meeting mode.
    {:ok, lv, _html} = live(conn, ~p"/dashboard")
    lv |> element("#calendar-grid") |> render_hook("show_create_form", %{})

    {:ok, lv: lv, user: user}
  end

  defp switch_off_main_participant(lv),
    do: lv |> element("#create-meeting-main-participant") |> render_click()

  defp add_guest(lv, email),
    do: lv |> form("#create-add-guest-form", %{"email" => email}) |> render_submit()

  defp put_title(lv, title),
    do: lv |> element("#create-event-title") |> render_blur(%{"value" => title})

  defp save(lv) do
    lv |> element("#create-event-modal button", "Create") |> render_click()
    render(lv)
  end

  test "the switch is on by default and asks for the main participant", %{lv: lv} do
    html = render(lv)

    assert has_element?(lv, ~s(#create-meeting-main-participant[aria-checked="true"]))
    assert html =~ "Main participant"
    assert html =~ "The main participant can move or cancel the meeting."
    assert has_element?(lv, "#create-meeting-guest-name")
    assert html =~ "More guests (optional)"
  end

  test "turning it off asks only for guests and says who manages the meeting", %{lv: lv} do
    html = switch_off_main_participant(lv)

    assert has_element?(lv, ~s(#create-meeting-main-participant[aria-checked="false"]))
    assert html =~ "Only you can move or cancel the meeting."
    refute has_element?(lv, "#create-meeting-guest-name")
    refute has_element?(lv, "#create-meeting-guest-email")
    refute html =~ "More guests (optional)"
    assert has_element?(lv, "#create-add-guest-form")
  end

  test "turning it off invites a main guest already typed in as the first guest", %{lv: lv} do
    lv
    |> element("#create-meeting-guest-email")
    |> render_blur(%{"value" => "Ada@Example.com"})

    add_guest(lv, "bob@example.com")
    switch_off_main_participant(lv)

    labels =
      lv
      |> render()
      |> Floki.parse_document!()
      |> Floki.find(~s(button[phx-click="remove_create_guest"]))
      |> Enum.map(&Floki.attribute(&1, "phx-value-email"))

    assert labels == [["ada@example.com"], ["bob@example.com"]]
  end

  test "the host cannot invite themselves as a guest", %{lv: lv, user: user} do
    switch_off_main_participant(lv)

    add_guest(lv, String.upcase(user.email))

    # The refusal is flashed by the dashboard, a message after the submit.
    assert render(lv) =~ "You cannot add yourself as a guest"
    refute has_element?(lv, ~s(button[phx-value-email="#{String.downcase(user.email)}"]))
  end

  test "saving without a guest says one is needed", %{lv: lv} do
    switch_off_main_participant(lv)
    put_title(lv, "Quarterly planning")

    html = save(lv)

    assert html =~ "Invite at least one guest."
    assert has_element?(lv, "#create-event-modal")
    refute Repo.exists?(MeetingSchema)
  end

  test "saving without a title says one is needed", %{lv: lv} do
    switch_off_main_participant(lv)
    add_guest(lv, "ada@example.com")

    html = save(lv)

    assert html =~ "Add a title."
    assert has_element?(lv, "#create-event-modal")
    refute Repo.exists?(MeetingSchema)
  end

  test "creates a meeting the host manages, with everyone invited as a guest", %{
    lv: lv,
    user: user
  } do
    switch_off_main_participant(lv)
    put_title(lv, "Quarterly planning")
    add_guest(lv, "ada@example.com")
    add_guest(lv, "bob@example.com")

    # An address still in the field when Create is pressed is invited too.
    lv
    |> element("#create-guest-email-input")
    |> render_change(%{"email" => "carol@example.com"})

    save(lv)

    # Creation runs in a supervised task; wait for the row it writes.
    meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: 5000)

    assert meeting.organizer_user_id == user.id
    assert meeting.managed_by_host
    assert meeting.title == "Quarterly planning"
    # The first guest fills the attendee fields a calendar entry needs, and
    # stays a guest like the others.
    assert meeting.attendee_email == "ada@example.com"

    guests = GuestQueries.list_for_meeting(meeting.id)

    assert guests |> Enum.map(& &1.email) |> Enum.sort() ==
             ["ada@example.com", "bob@example.com", "carol@example.com"]

    assert Enum.all?(guests, &(&1.invited_by == :organizer))
  end

  test "switching back on books with a main participant as before", %{lv: lv} do
    switch_off_main_participant(lv)
    switch_off_main_participant(lv)

    lv |> element("#create-meeting-guest-name") |> render_blur(%{"value" => "Ada Lovelace"})
    lv |> element("#create-meeting-guest-email") |> render_blur(%{"value" => "ada@example.com"})

    save(lv)

    meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: 5000)

    refute meeting.managed_by_host
    assert meeting.attendee_name == "Ada Lovelace"
    assert meeting.title == "Meeting with Ada Lovelace"
  end
end
