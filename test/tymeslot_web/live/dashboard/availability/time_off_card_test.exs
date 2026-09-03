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

  alias Tymeslot.Availability.{Schedules, TimeOff}
  alias Tymeslot.Infrastructure.AvailabilityCache

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

  describe "removing" do
    test "deletes the period after confirmation", %{conn: conn, profile: profile} do
      period = insert(:time_off_period, profile: profile, label: "Portugal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_delete_time_off'][phx-value-id='#{period.id}']")
      |> render_click()

      view |> element("#delete-time-off-modal button", "Remove") |> render_click()

      assert TimeOff.list(profile.id) == []
      assert render(view) =~ "No time off booked"
    end
  end
end
