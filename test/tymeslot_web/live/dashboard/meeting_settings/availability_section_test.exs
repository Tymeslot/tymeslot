defmodule TymeslotWeb.Dashboard.MeetingSettings.AvailabilitySectionTest do
  @moduledoc """
  LiveView coverage for the meeting-type form's Availability section — the
  user journey where a host points a meeting type at one of their named
  availability schedules, or leaves it following the profile's default.

  A blank selection is stored as `nil`, so the meeting type keeps tracking
  whichever schedule is currently the default rather than pinning the one that
  happened to be default at the time.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  setup %{profile: profile} do
    {:ok, default} = Schedules.create_default(profile.id)
    {:ok, evenings} = Schedules.create(profile.id, %{name: "Evenings"})

    %{default_schedule: default, evenings: evenings}
  end

  describe "Choosing a schedule while creating a meeting type" do
    test "persists the chosen availability_schedule_id", %{
      conn: conn,
      user: user,
      evenings: evenings
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

      html = render(view)
      assert html =~ "Default (Working hours)"
      assert html =~ "Evenings"

      # Remove the default reminder so the hidden reminder inputs do not break
      # Plug.Conn.Query re-encoding on submit (the same workaround the other
      # create-path tests use).
      view |> element("button[aria-label='Remove reminder']") |> render_click()

      view
      |> element(~s|select[name="meeting_type[availability_schedule_id]"]|)
      |> render_change(%{
        "meeting_type" => %{"availability_schedule_id" => to_string(evenings.id)}
      })

      view
      |> form("form[phx-submit='save_meeting_type']", %{
        "meeting_type" => %{"name" => "Evening Chat", "duration" => "30"}
      })
      |> render_submit()

      assert render(view) =~ "Meeting type created"

      created =
        Enum.find(MeetingTypes.get_all_meeting_types(user.id), &(&1.name == "Evening Chat"))

      assert created.availability_schedule_id == evenings.id
    end
  end

  describe "Falling back to the default schedule while editing" do
    test "choosing the blank default option persists nil", %{
      conn: conn,
      user: user,
      evenings: evenings
    } do
      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Pinned Type",
          duration_minutes: 30,
          availability_schedule_id: evenings.id
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view |> element("#tab-booking") |> render_click()

      view
      |> element(~s|select[name="meeting_type[availability_schedule_id]"]|)
      |> render_change(%{"meeting_type" => %{"availability_schedule_id" => ""}})

      # Edits auto-save, so the change is persisted without any submit.
      assert render(view) =~ "All changes saved"

      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).availability_schedule_id ==
               nil
    end
  end
end
