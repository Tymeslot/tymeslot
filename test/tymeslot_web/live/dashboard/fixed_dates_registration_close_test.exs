defmodule TymeslotWeb.Dashboard.FixedDatesRegistrationCloseTest do
  @moduledoc """
  Where the dashboard tells the host about registration for fixed dates:
  moving a date's registration close in the meeting-type form, the meeting
  type card's next open date (or the lack of one), and the meetings list
  marking a session whose registration has closed. Driven through the
  pages' own controls.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :setup_dashboard_user

  setup %{user: user, profile: profile} do
    TestMocks.setup_all_mocks()
    profile |> Changeset.change(timezone: "Etc/UTC") |> Repo.update!()
    venue = insert(:venue, user: user, name: "Main Hall")

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Introduction to X",
        duration_minutes: 90,
        max_participants: 10,
        fixed_dates: true,
        locations: [in_person_location([venue])]
      )

    %{meeting_type: meeting_type}
  end

  defp at(days, time), do: Date.utc_today() |> Date.add(days) |> DateTime.new!(time, "Etc/UTC")

  defp local(datetime), do: Calendar.strftime(datetime, "%Y-%m-%dT%H:%M")

  defp edit(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view |> element("#meeting-type-form-tabs-tab-booking") |> render_click()
    view
  end

  defp edit_date(view, session, fields) do
    view
    |> element("[data-testid='edit-session-button'][phx-value-id='#{session.id}']")
    |> render_click()

    for {field, value} <- fields do
      view
      |> element("input[name='session_edit[#{field}]']")
      |> render_change(%{"session_edit" => %{field => value}})
    end

    view |> element("[data-testid='save-session-edit']") |> render_click()
  end

  defp move_close(view, session, value), do: edit_date(view, session, %{"closes_at" => value})

  describe "the meeting-type form" do
    test "moves a date's registration close, and closes it at once", ctx do
      {:ok, session} =
        PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]),
          registration_closes_at: at(2, ~T[12:00:00])
        )

      view = edit(ctx.conn, ctx.meeting_type)

      move_close(view, session, local(at(9, ~T[20:00:00])))

      assert Repo.reload!(session).registration_closes_at == at(9, ~T[20:00:00])
      refute has_element?(view, "[data-testid='edit-session']")
      assert has_element?(view, "[data-testid='planned-session']", "registration until")

      move_close(view, session, local(at(-1, ~T[12:00:00])))

      refute PlannedSessions.open?(Repo.reload!(session))
      assert has_element?(view, "[data-testid='session-registration-closed']")
    end

    test "refuses a close after the start and says why", ctx do
      {:ok, session} = PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]))
      view = edit(ctx.conn, ctx.meeting_type)

      move_close(view, session, local(at(11, ~T[12:00:00])))

      assert has_element?(view, "[data-testid='edit-session']", "no later than")
      assert Repo.reload!(session).registration_closes_at == nil
    end
  end

  describe "moving a date" do
    test "moves it with everyone booked on it, who are told", ctx do
      {:ok, session} = PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]))
      participant = insert(:participant, meeting: session, name: "Ada Lovelace")
      view = edit(ctx.conn, ctx.meeting_type)

      edit_date(view, session, %{
        "date" => Date.to_iso8601(Date.add(Date.utc_today(), 12)),
        "time" => "09:30"
      })

      moved = Repo.reload!(session)
      assert moved.start_time == at(12, ~T[09:30:00])
      assert moved.end_time == at(12, ~T[11:00:00])
      refute has_element?(view, "[data-testid='edit-session']")

      assert_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{
          "action" => "send_seat_session_moved",
          "meeting_id" => session.id,
          "participant_id" => participant.id
        }
      )
    end

    test "says when the host has another booking at the new time", ctx do
      {:ok, session} = PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]))
      {:ok, _other} = PlannedSessions.add(ctx.meeting_type, at(12, ~T[09:00:00]))
      view = edit(ctx.conn, ctx.meeting_type)

      edit_date(view, session, %{
        "date" => Date.to_iso8601(Date.add(Date.utc_today(), 12)),
        "time" => "09:30"
      })

      assert has_element?(view, "[data-testid='edit-session']", "already have a booking")
      assert Repo.reload!(session).start_time == at(10, ~T[18:00:00])
    end
  end

  describe "the meeting type card" do
    test "names the next date open for registration", ctx do
      {:ok, _session} = PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]))

      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")

      assert has_element?(view, "[data-testid='next-fixed-date']", "Next date:")
      refute has_element?(view, "[data-testid='no-open-dates']")
    end

    test "says when no date is open for registration", ctx do
      {:ok, session} = PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]))
      {:ok, _closed} = PlannedSessions.set_registration_close(session, at(-1, ~T[12:00:00]))

      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")

      assert has_element?(view, "[data-testid='no-open-dates']", "No open dates")
      refute has_element?(view, "[data-testid='next-fixed-date']")
    end
  end

  describe "the meetings list" do
    test "offers no reschedule request for a session, which moves from its type", ctx do
      {:ok, session} = PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]))
      insert(:participant, meeting: session, name: "Ada Lovelace")

      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meetings")

      assert has_element?(view, "button[phx-click='show_reschedule_modal'][disabled]")
    end

    test "marks an upcoming session whose registration has closed", ctx do
      {:ok, session} = PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]))
      insert(:participant, meeting: session, name: "Ada Lovelace")

      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meetings")
      refute has_element?(view, "[data-testid='registration-closed-badge']")

      {:ok, _closed} = PlannedSessions.set_registration_close(session, at(-1, ~T[12:00:00]))

      {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meetings")

      assert has_element?(
               view,
               "[data-testid='registration-closed-badge']",
               "Registration closed"
             )
    end
  end
end
