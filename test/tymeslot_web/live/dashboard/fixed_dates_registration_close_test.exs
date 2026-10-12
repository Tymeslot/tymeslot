defmodule TymeslotWeb.Dashboard.FixedDatesRegistrationCloseTest do
  @moduledoc """
  Where the dashboard tells the host about registration for fixed dates:
  moving a date's registration close in the meeting-type form, the meeting
  type card's next open date (or the lack of one), and the meetings list
  marking a session whose registration has closed. Driven through the
  pages' own controls.
  """

  use TymeslotWeb.LiveCase, async: false

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

  defp move_close(view, value) do
    view |> element("[data-testid='edit-session-close-button']") |> render_click()

    view
    |> element("input[name='session_close[closes_at]']")
    |> render_change(%{"session_close" => %{"closes_at" => value}})

    view |> element("[data-testid='save-session-close']") |> render_click()
  end

  describe "the meeting-type form" do
    test "moves a date's registration close, and closes it at once", ctx do
      {:ok, session} =
        PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]),
          registration_closes_at: at(2, ~T[12:00:00])
        )

      view = edit(ctx.conn, ctx.meeting_type)

      move_close(view, local(at(9, ~T[20:00:00])))

      assert Repo.reload!(session).registration_closes_at == at(9, ~T[20:00:00])
      refute has_element?(view, "[data-testid='edit-session-close']")
      assert has_element?(view, "[data-testid='planned-session']", "registration until")

      move_close(view, local(at(-1, ~T[12:00:00])))

      refute PlannedSessions.open?(Repo.reload!(session))
      assert has_element?(view, "[data-testid='session-registration-closed']")
    end

    test "refuses a close after the start and says why", ctx do
      {:ok, session} = PlannedSessions.add(ctx.meeting_type, at(10, ~T[18:00:00]))
      view = edit(ctx.conn, ctx.meeting_type)

      move_close(view, local(at(11, ~T[12:00:00])))

      assert has_element?(view, "[data-testid='edit-session-close']", "no later than")
      assert Repo.reload!(session).registration_closes_at == nil
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
