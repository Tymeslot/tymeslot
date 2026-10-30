defmodule TymeslotWeb.Dashboard.MeetingTypeFormFixedDatesGuardsTest do
  @moduledoc """
  The meeting-type form's fixed dates against what the page on screen
  cannot be trusted with: events forged with another host's date, a date
  booked after the page rendered, and local times a clock change skips or
  repeats.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  # The form component's root, which events of its own are sent to.
  @form "[id^='meeting-type-form-wrapper-']"

  setup :setup_dashboard_user

  setup %{user: user} do
    TestMocks.setup_all_mocks()
    %{meeting_type: fixed_type(user)}
  end

  defp fixed_type(user) do
    venue = insert(:venue, user: user, name: "Main Hall")

    insert(:meeting_type,
      user: user,
      name: "Introduction to X",
      duration_minutes: 90,
      max_participants: 10,
      fixed_dates: true,
      locations: [in_person_location([venue])]
    )
  end

  defp at(days, time), do: Date.utc_today() |> Date.add(days) |> DateTime.new!(time, "Etc/UTC")

  defp plan!(meeting_type, starts_at) do
    {:ok, session} = PlannedSessions.add(meeting_type, meeting_type.user_id, starts_at)
    session
  end

  defp edit(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view |> element("#meeting-type-form-tabs-tab-booking") |> render_click()
    view
  end

  defp forge(view, event, params), do: view |> with_target(@form) |> render_click(event, params)

  defp book_seat(user, meeting_type, starts_at) do
    {:ok, _seat} =
      Create.execute(
        %{
          date: DateTime.to_date(starts_at),
          time: Calendar.strftime(starts_at, "%H:%M"),
          duration: "90min",
          user_timezone: "Etc/UTC",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id
        },
        %{"name" => "Booker", "email" => "booker@example.com"}
      )
  end

  describe "events forged with another host's date" do
    setup do
      other = insert(:user)
      insert(:profile, user: other)
      other_type = fixed_type(other)
      %{other_type: other_type, other_session: plan!(other_type, at(12, ~T[18:00:00]))}
    end

    test "cancel neither at once nor after asking", ctx do
      plan!(ctx.meeting_type, at(10, ~T[18:00:00]))
      view = edit(ctx.conn, ctx.meeting_type)

      forge(view, "remove_session", %{"id" => ctx.other_session.id})
      refute has_element?(view, "[data-testid='confirm-cancel-session']")

      forge(view, "cancel_session", %{"id" => ctx.other_session.id})

      assert Repo.get!(MeetingSchema, ctx.other_session.id).status == :confirmed
    end

    test "neither open the date for editing nor move it", ctx do
      plan!(ctx.meeting_type, at(10, ~T[18:00:00]))
      view = edit(ctx.conn, ctx.meeting_type)

      forge(view, "edit_session", %{"id" => ctx.other_session.id})
      refute has_element?(view, "[data-testid='edit-session']")

      forge(view, "update_session_edit", %{
        "session_edit" => %{"date" => Date.to_iso8601(Date.add(Date.utc_today(), 20))}
      })

      forge(view, "save_session_edit", %{"id" => ctx.other_session.id})

      assert Repo.get!(MeetingSchema, ctx.other_session.id).start_time ==
               ctx.other_session.start_time
    end

    test "plan nothing on the other host's type", ctx do
      view = edit(ctx.conn, ctx.meeting_type)
      date = Date.to_iso8601(Date.add(Date.utc_today(), 15))

      forge(view, "update_session_input", %{"session" => %{"date" => date, "time" => "09:00"}})
      forge(view, "add_session", %{"id" => ctx.other_type.id, "type_id" => ctx.other_type.id})

      assert [%{id: id}] = PlannedSessions.list(ctx.other_type)
      assert id == ctx.other_session.id
      # The date went on the host's own type, the only one the form edits.
      assert [_own] = PlannedSessions.list(ctx.meeting_type)
    end
  end

  test "a date booked after the page rendered asks before it is cancelled", ctx do
    starts_at = at(10, ~T[18:00:00])
    session = plan!(ctx.meeting_type, starts_at)
    view = edit(ctx.conn, ctx.meeting_type)

    book_seat(ctx.user, ctx.meeting_type, starts_at)
    view |> element("[data-testid='remove-session']") |> render_click()

    assert Repo.get!(MeetingSchema, session.id).status == :confirmed
    assert render(view) =~ "1 person is booked and will be told"
  end

  describe "a local time the clock change" do
    setup %{profile: profile} do
      profile |> Changeset.change(timezone: "Europe/Berlin") |> Repo.update!()
      :ok
    end

    # The next day on which 02:30 in Berlin is skipped (`:gap`) or happens
    # twice (`:ambiguous`).
    defp clock_change_day(kind) do
      1..400
      |> Stream.map(&Date.add(Date.utc_today(), &1))
      |> Enum.find(&(elem(DateTime.new(&1, ~T[02:30:00], "Europe/Berlin"), 0) == kind))
    end

    defp plan_at(view, date) do
      fields = %{"date" => Date.to_iso8601(date), "time" => "02:30"}
      forge(view, "update_session_input", %{"session" => fields})
      view |> element("[data-testid='add-session']") |> render_click()
    end

    test "skips is planned at the end of the gap", ctx do
      date = clock_change_day(:gap)
      view = edit(ctx.conn, ctx.meeting_type)

      plan_at(view, date)

      refute has_element?(view, "[data-testid='session-error']")
      assert [session] = PlannedSessions.list(ctx.meeting_type)
      # 03:00 summer time.
      assert session.start_time == DateTime.new!(date, ~T[01:00:00], "Etc/UTC")
    end

    test "repeats is planned at its first occurrence", ctx do
      date = clock_change_day(:ambiguous)
      view = edit(ctx.conn, ctx.meeting_type)

      plan_at(view, date)

      refute has_element?(view, "[data-testid='session-error']")
      assert [session] = PlannedSessions.list(ctx.meeting_type)
      # 02:30 still on summer time, before the clocks go back.
      assert session.start_time == DateTime.new!(date, ~T[00:30:00], "Etc/UTC")
    end
  end
end
