defmodule TymeslotWeb.Dashboard.Availability.TimeOffCardTest do
  @moduledoc """
  Covers the time-off card on the availability page: adding, editing and
  removing a period through the UI, and the two guards a submitted form has to
  clear — a validation failure that must keep what was typed, and an id that
  belongs to another account.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Availability.{Schedules, TimeOff}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo

  setup %{conn: conn} do
    AvailabilityCache.clear_all()
    {:ok, ctx} = setup_dashboard_user(%{conn: conn})
    {:ok, _schedule} = Schedules.create_default(ctx[:profile].id)

    ctx
  end

  describe "listing" do
    test "shows the empty state when nothing is booked", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      assert html =~ "Time Off"
      assert html =~ "No time off booked"
      refute html =~ ~s(data-testid="time-off-current")
    end

    test "lists a whole-day period by its dates alone", %{conn: conn, profile: profile} do
      insert(:time_off_period,
        profile: profile,
        starts_on: ~D[2027-07-05],
        ends_on: ~D[2027-07-12],
        label: "Portugal"
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")
      html = render(view)

      assert html =~ "Portugal"
      assert html =~ "July 5, 2027"
      assert html =~ "July 12, 2027"
      # A whole-day period must not be dressed up with the times it does not have.
      refute html =~ "from 00:00"
      refute html =~ "until 23:59"
    end

    test "shows the times of a part-day period", %{conn: conn, profile: profile} do
      insert(:time_off_period,
        profile: profile,
        starts_on: ~D[2027-07-05],
        ends_on: ~D[2027-07-05],
        start_time: ~T[13:00:00],
        end_time: ~T[17:00:00],
        label: nil
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")
      html = render(view)

      assert html =~ "13:00"
      assert html =~ "17:00"
    end
  end

  describe "adding" do
    test "stores a whole-day period submitted from the form", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      view
      |> form("#time-off-form-modal-form", %{
        "starts_on" => "2027-07-05",
        "ends_on" => "2027-07-12",
        "start_time" => "",
        "end_time" => "",
        "label" => "Portugal"
      })
      |> render_submit()

      assert [period] = TimeOff.list(profile.id)
      assert period.starts_on == ~D[2027-07-05]
      assert period.ends_on == ~D[2027-07-12]
      assert period.start_time == nil
      assert period.end_time == nil
      assert period.label == "Portugal"

      assert render(view) =~ "Portugal"
    end

    test "stores the times of a part-day period", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      view
      |> form("#time-off-form-modal-form", %{
        "starts_on" => "2027-07-05",
        "ends_on" => "2027-07-05",
        "start_time" => "13:00",
        "end_time" => "17:00",
        "label" => ""
      })
      |> render_submit()

      assert [period] = TimeOff.list(profile.id)
      assert period.start_time == ~T[13:00:00]
      assert period.end_time == ~T[17:00:00]
      assert period.label == nil
    end

    test "keeps the form open with the dates typed when the range is backwards", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      html =
        view
        |> form("#time-off-form-modal-form", %{
          "starts_on" => "2027-07-12",
          "ends_on" => "2027-07-05",
          "start_time" => "",
          "end_time" => "",
          "label" => "Portugal"
        })
        |> render_submit()

      assert TimeOff.list(profile.id) == []

      # The form must still be there, still carrying the dates, with the reason
      # against the field it belongs to; a closed modal would discard the input.
      assert html =~ "must not be before the start date"
      assert html =~ "2027-07-12"
      assert html =~ "Portugal"
    end
  end

  describe "the form" do
    test "links every label to its field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      for field <- ~w(starts-on ends-on start-time end-time label) do
        id = "time-off-form-modal-#{field}"
        assert has_element?(view, "label[for='#{id}']")
        assert has_element?(view, "##{id}")
      end
    end

    test "treats a malformed field in a hand-built event as blank rather than crashing", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      html =
        view
        |> element("#time-off-form-modal-form")
        |> render_submit(%{
          "starts_on" => %{"nested" => "2027-07-05"},
          "ends_on" => "2027-07-12",
          "label" => ["Portugal"]
        })

      assert html =~ "can&#39;t be blank"
      assert TimeOff.list(profile.id) == []
      assert render(view) =~ "Time Off"
    end
  end

  describe "past periods" do
    test "appear in their own section, without an edit button, for 30 days", %{
      conn: conn,
      profile: profile
    } do
      today = TimeOff.today(profile.timezone)

      recent =
        insert(:time_off_period,
          profile: profile,
          starts_on: Date.add(today, -10),
          ends_on: Date.add(today, -8),
          label: "Recent trip"
        )

      insert(:time_off_period,
        profile: profile,
        starts_on: Date.add(today, -45),
        ends_on: Date.add(today, -40),
        label: "Long ago"
      )

      {:ok, view, html} = live(conn, ~p"/dashboard/availability")

      assert has_element?(view, "[data-testid='time-off-past-list']", "Recent trip")
      refute has_element?(view, "[data-testid='time-off-list']")
      # Nothing coming up still gets its own, empty category above the past one,
      # rather than the whole-card empty state.
      assert has_element?(view, "[data-testid='time-off-current-empty']")
      refute html =~ "No time off booked"
      refute html =~ "Long ago"

      refute has_element?(
               view,
               "button[phx-click='show_time_off_form'][phx-value-id='#{recent.id}']"
             )

      assert has_element?(
               view,
               "#time-off-past-#{recent.id} button[aria-label='Remove time off']"
             )
    end
  end

  describe "removing a past period" do
    test "removes it at once, without the confirmation dialog", %{conn: conn, profile: profile} do
      today = TimeOff.today(profile.timezone)

      past =
        insert(:time_off_period,
          profile: profile,
          starts_on: Date.add(today, -10),
          ends_on: Date.add(today, -8)
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("#time-off-past-#{past.id} button[aria-label='Remove time off']")
      |> render_click()

      assert TimeOff.list(profile.id) == []
      refute has_element?(view, "#time-off-past-#{past.id}")
      refute render(view) =~ "Those days become bookable again straight away."
    end
  end

  describe "past dates" do
    test "flags a first day in the past beside the field before the form is submitted", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      html =
        view
        |> form("#time-off-form-modal-form", %{"starts_on" => "2020-01-06", "ends_on" => ""})
        |> render_change()

      assert html =~ "must not be in the past"
      # The last day is still empty: that is for the submit to complain about,
      # not something to shout while the form is being filled in.
      refute html =~ "can&#39;t be blank"
    end

    test "shows the error in the dashboard's language", %{conn: conn, user: user} do
      user |> Changeset.change(locale: "de") |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      html =
        view
        |> form("#time-off-form-modal-form", %{"starts_on" => "2020-01-06", "ends_on" => ""})
        |> render_change()

      assert html =~ "darf nicht in der Vergangenheit liegen"
    end

    test "refuses to save a period in the past and keeps the form open", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      html =
        view
        |> form("#time-off-form-modal-form", %{
          "starts_on" => "2020-01-06",
          "ends_on" => "2020-01-10",
          "start_time" => "",
          "end_time" => "",
          "label" => "Portugal"
        })
        |> render_submit()

      assert TimeOff.list(profile.id) == []
      assert html =~ "must not be in the past"
      assert html =~ "2020-01-06"
    end

    test "a period already under way can still be edited", %{conn: conn, profile: profile} do
      period =
        insert(:time_off_period,
          profile: profile,
          starts_on: ~D[2020-01-06],
          ends_on: ~D[2099-01-10],
          label: "Sabbatical"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      html =
        view
        |> element("button[phx-click='show_time_off_form'][phx-value-id='#{period.id}']")
        |> render_click()

      # The picker must reach back to the stored first day, or the browser
      # would refuse to submit the form at all.
      assert html =~ ~s(min="2020-01-06")

      view
      |> form("#time-off-form-modal-form", %{
        "starts_on" => "2020-01-06",
        "ends_on" => "2099-01-10",
        "start_time" => "",
        "end_time" => "",
        "label" => "Long sabbatical"
      })
      |> render_submit()

      assert [%{label: "Long sabbatical"}] = TimeOff.list(profile.id)
    end
  end

  describe "editing" do
    test "loads the period into the form and saves the change", %{conn: conn, profile: profile} do
      period =
        insert(:time_off_period,
          profile: profile,
          starts_on: ~D[2027-07-05],
          ends_on: ~D[2027-07-12],
          label: "Portugal"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      html =
        view
        |> element("button[phx-click='show_time_off_form'][phx-value-id='#{period.id}']")
        |> render_click()

      assert html =~ "2027-07-05"
      assert html =~ "Portugal"

      view
      |> form("#time-off-form-modal-form", %{
        "starts_on" => "2027-07-05",
        "ends_on" => "2027-07-19",
        "start_time" => "",
        "end_time" => "",
        "label" => "Portugal"
      })
      |> render_submit()

      assert [%{ends_on: ~D[2027-07-19]}] = TimeOff.list(profile.id)
    end

    test "will not edit a period belonging to another account", %{conn: conn, profile: profile} do
      mine =
        insert(:time_off_period,
          profile: profile,
          starts_on: ~D[2027-07-05],
          ends_on: ~D[2027-07-12]
        )

      theirs = insert(:time_off_period, starts_on: ~D[2028-01-05], ends_on: ~D[2028-01-12])

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # Their id, submitted through this account's own edit button, is the shape
      # a tampered payload takes: the event is legitimate, the id is not.
      html =
        view
        |> element("button[phx-click='show_time_off_form'][phx-value-id='#{mine.id}']")
        |> render_click(%{"id" => to_string(theirs.id)})

      refute html =~ "2028-01-05"
      assert Enum.map(TimeOff.list(profile.id), & &1.id) == [mine.id]
      assert TimeOff.list(theirs.profile_id) != []
    end
  end

  describe "bookings inside the dates" do
    test "names them while the dates are being chosen, and saves anyway", %{
      conn: conn,
      profile: profile,
      user: user
    } do
      booking(user, ~U[2027-07-06 12:00:00Z], "Design review")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      html =
        view
        |> form("#time-off-form-modal-form", %{
          "starts_on" => "2027-07-05",
          "ends_on" => "2027-07-12"
        })
        |> render_change()

      assert html =~ "1 booking already sits inside these dates"
      assert html =~ "Design review"

      # Warned, never blocked: the host is the one who decides what happens to
      # a booking they have already made.
      view
      |> form("#time-off-form-modal-form", %{
        "starts_on" => "2027-07-05",
        "ends_on" => "2027-07-12",
        "start_time" => "",
        "end_time" => "",
        "label" => "Portugal"
      })
      |> render_submit()

      assert [%{label: "Portugal"}] = TimeOff.list(profile.id)

      html = render(view)
      assert html =~ "Time off added"
      assert html =~ "1 booking sits inside this time off"
    end

    test "says nothing when the dates are clear", %{conn: conn, user: user} do
      booking(user, ~U[2027-08-20 12:00:00Z], "Design review")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[data-testid='add-time-off']") |> render_click()

      html =
        view
        |> form("#time-off-form-modal-form", %{
          "starts_on" => "2027-07-05",
          "ends_on" => "2027-07-12"
        })
        |> render_change()

      refute html =~ ~s(data-testid="time-off-conflicts")
      refute html =~ "Design review"
    end

    test "warns as an existing period's last day is pushed out", %{
      conn: conn,
      profile: profile,
      user: user
    } do
      period =
        insert(:time_off_period,
          profile: profile,
          starts_on: ~D[2027-07-05],
          ends_on: ~D[2027-07-12]
        )

      booking(user, ~U[2027-07-15 12:00:00Z], "Client call")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      html =
        view
        |> element("button[phx-click='show_time_off_form'][phx-value-id='#{period.id}']")
        |> render_click()

      refute html =~ "Client call"

      html =
        view
        |> form("#time-off-form-modal-form", %{
          "starts_on" => "2027-07-05",
          "ends_on" => "2027-07-19"
        })
        |> render_change()

      assert html =~ "1 booking already sits inside these dates"
      assert html =~ "Client call"
    end
  end

  describe "removing" do
    test "deletes the period after confirmation", %{conn: conn, profile: profile} do
      period = insert(:time_off_period, profile: profile, label: "Portugal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("#time-off-#{period.id} button[aria-label='Remove time off']")
      |> render_click()

      view |> element("#delete-time-off-modal button", "Remove") |> render_click()

      assert TimeOff.list(profile.id) == []
      assert render(view) =~ "No time off booked"
    end
  end

  defp booking(user, start_time, title) do
    insert(:meeting,
      organizer_user_id: user.id,
      title: title,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute)
    )
  end
end
