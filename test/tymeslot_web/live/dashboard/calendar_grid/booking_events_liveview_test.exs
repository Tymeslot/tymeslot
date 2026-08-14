defmodule TymeslotWeb.Dashboard.CalendarGrid.BookingEventsLiveviewTest do
  @moduledoc """
  Covers Tymeslot bookings rendered natively on the calendar grid: read-only
  booking blocks with no integration connected, the booking detail modal, the
  connect-a-calendar banner, and deduplication against a synced provider copy.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Onboarding

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  defp insert_booking(user, attrs \\ %{}) do
    start_time = DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC")

    defaults = %{
      organizer_user: user,
      title: "Discovery call",
      attendee_name: "Ada Lovelace",
      attendee_email: "ada@example.com",
      start_time: start_time,
      end_time: DateTime.add(start_time, 3600, :second),
      status: "confirmed"
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  describe "bookings on the grid without any integration" do
    test "renders the booking as a read-only block", %{conn: conn, user: user} do
      meeting = insert_booking(user)

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Discovery call"
      assert html =~ ~s(phx-value-meeting-id="#{meeting.id}")
      assert html =~ ~s(phx-click="show_booking")

      # The block is not draggable and offers no resize handle.
      assert html =~ ~s(data-event-id="booking-#{meeting.id}")
      refute html =~ ~s(id="event-booking-#{meeting.id}) <> ~s(" data-draggable="true")
    end

    test "shows the connect-a-calendar banner instead of a blocking empty state",
         %{conn: conn, user: user} do
      # The banner defers to the setup checklist, which carries the same
      # "Connect a calendar" step, so dismiss the checklist first.
      {:ok, _user} = Onboarding.dismiss_dashboard_setup(user)

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "data-testid=\"connect-calendar-banner\""
      assert html =~ "Bring your calendar into Tymeslot"
      refute html =~ "Nothing to see here"
    end

    test "defers the banner to the setup checklist while setup is incomplete",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "data-testid=\"onboarding-checklist\""
      refute html =~ "data-testid=\"connect-calendar-banner\""
    end

    test "hides the banner once an integration is connected", %{conn: conn, user: user} do
      insert(:calendar_integration, user: user, is_active: true)

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "data-testid=\"connect-calendar-banner\""
    end
  end

  describe "booking detail modal" do
    test "opens with booking details and closes again", %{conn: conn, user: user} do
      meeting = insert_booking(user)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html =
        lv
        |> element(~s{[data-event-id="booking-#{meeting.id}"]})
        |> render_click()

      assert html =~ "booking-detail-modal"
      assert html =~ "Ada Lovelace"
      assert html =~ "ada@example.com"
      assert html =~ "Booked through your Tymeslot page"
      assert html =~ "Manage in Meetings"

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("close_booking_detail", %{})

      refute html =~ "booking-detail-modal"
    end

    test "ignores an unknown meeting id", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("show_booking", %{"meeting-id" => "999999"})

      refute html =~ "booking-detail-modal"
    end
  end

  describe "agenda bookings lens" do
    test "filters the agenda down to bookings", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      day = Date.add(Date.utc_today(), 2)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "External standup",
        start_at: DateTime.new!(day, ~T[09:00:00], "Etc/UTC"),
        end_at: DateTime.new!(day, ~T[10:00:00], "Etc/UTC"),
        all_day: false
      )

      insert_booking(user, %{
        title: "Booked discovery",
        start_time: DateTime.new!(day, ~T[11:00:00], "Etc/UTC"),
        end_time: DateTime.new!(day, ~T[12:00:00], "Etc/UTC")
      })

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      # Scope to the agenda container: other (hidden) views keep their own
      # copies of the events in the DOM.
      agenda_text = fn html ->
        html |> Floki.parse_document!() |> Floki.find("#calendar-agenda") |> Floki.text()
      end

      html = lv |> element("#calendar-grid") |> render_hook("set_view", %{"view" => "agenda"})
      assert agenda_text.(html) =~ "External standup"
      assert agenda_text.(html) =~ "Booked discovery"

      html = lv |> element(~s{[data-testid="agenda-lens-bookings"]}) |> render_click()
      refute agenda_text.(html) =~ "External standup"
      assert agenda_text.(html) =~ "Booked discovery"

      html = lv |> element(~s{[data-testid="agenda-lens-all"]}) |> render_click()
      assert agenda_text.(html) =~ "External standup"
    end
  end

  describe "deduplication against a synced provider copy" do
    test "shows only the synced provider event for a written-back booking",
         %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      meeting = insert_booking(user, %{provider_event_id: "prov-1"})

      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Discovery call (synced)",
        provider_event_id: "prov-1",
        created_by_tymeslot: true,
        start_at: meeting.start_time,
        end_at: meeting.end_time,
        all_day: false
      )

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Discovery call (synced)"
      refute html =~ ~s(data-event-id="booking-#{meeting.id}")
    end
  end
end
