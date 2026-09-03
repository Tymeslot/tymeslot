defmodule TymeslotWeb.Dashboard.MeetingSettings.LocationsEditorTest do
  @moduledoc """
  The host's side of guest-chosen locations: the list in the meeting type
  form's Location tab, and the modal editor behind it.

  Both push their results into the parent form component, which auto-saves,
  so these drive the real dashboard LiveView and read the persisted meeting
  type back rather than asserting on socket state.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.LocationOption

  setup :setup_dashboard_user

  defp open_editor(%{conn: conn, user: user}, locations) do
    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Consultation",
        duration_minutes: 30,
        locations: locations
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view |> element("[phx-click='switch_tab'][phx-value-tab='location']") |> render_click()

    {view, meeting_type}
  end

  # The editor and the list both mutate via `send_update`, which is delivered
  # as a message *after* the event round-trip returns. Draining the LiveView's
  # mailbox is what makes the auto-save it triggers observable here.
  defp reload(view, meeting_type, user) do
    _drain = :sys.get_state(view.pid)
    MeetingTypes.get_meeting_type(meeting_type.id, user.id)
  end

  defp office do
    %LocationOption{
      id: "loc-office",
      kind: "in_person",
      label: "Our office",
      details: "12 High Street",
      position: 0
    }
  end

  describe "the locations list" do
    test "shows each configured location", ctx do
      {view, _type} =
        open_editor(ctx, [
          office(),
          %LocationOption{
            id: "loc-call",
            kind: "phone",
            label: "Ring us",
            details: "+44",
            position: 1
          }
        ])

      html = render(view)
      assert html =~ "Our office"
      assert html =~ "12 High Street"
      assert html =~ "Ring us"
      assert html =~ "Bookers will be asked to choose one of these."
    end

    test "a single location says what adding another would do", ctx do
      {view, _type} = open_editor(ctx, [office()])

      assert render(view) =~ "Add a second location and bookers will be asked to choose."
    end

    test "the only location cannot be deleted, so the type keeps somewhere to be held", ctx do
      {view, _type} = open_editor(ctx, [office()])

      refute has_element?(view, "[phx-click='delete_location'][phx-value-id='loc-office']")
    end
  end

  describe "adding a location" do
    test "persists it alongside the existing one", %{user: user} = ctx do
      {view, meeting_type} = open_editor(ctx, [office()])

      view |> element("button[data-testid='add-location']") |> render_click()

      view
      |> form("#location-editor-form", %{
        "location" => %{
          "kind" => "in_person",
          "label" => "The workshop",
          "details" => "Unit 4, Mill Lane"
        }
      })
      |> render_submit()

      assert [%{label: "Our office"}, workshop] = reload(view, meeting_type, user).locations
      assert workshop.label == "The workshop"
      assert workshop.details == "Unit 4, Mill Lane"
      assert workshop.position == 1
    end

    test "a video location binds to one of the host's integrations", %{user: user} = ctx do
      integration = insert(:video_integration, user: user, name: "Team Room", is_active: true)
      {view, meeting_type} = open_editor(ctx, [office()])

      view |> element("button[data-testid='add-location']") |> render_click()

      # Choosing the kind is what reveals the provider picker, so the change
      # has to land before the form carries an integration id at all.
      view
      |> form("#location-editor-form", %{"location" => %{"kind" => "video"}})
      |> render_change()

      view
      |> form("#location-editor-form", %{
        "location" => %{
          "kind" => "video",
          "label" => "Team Room",
          "video_integration_id" => to_string(integration.id)
        }
      })
      |> render_submit()

      reloaded = reload(view, meeting_type, user)

      assert [_office, video] = reloaded.locations
      assert video.kind == "video"
      assert video.video_integration_id == integration.id

      # The pair every pre-list reader still consults is projected from it.
      assert reloaded.allow_video == true
      assert reloaded.video_integration_id == integration.id
    end

    test "refuses a video location that names no integration", %{user: user} = ctx do
      {view, meeting_type} = open_editor(ctx, [office()])

      view |> element("button[data-testid='add-location']") |> render_click()

      view
      |> form("#location-editor-form", %{"location" => %{"kind" => "video"}})
      |> render_change()

      view
      |> form("#location-editor-form", %{
        "location" => %{"kind" => "video", "label" => "Nowhere"}
      })
      |> render_submit()

      # The editor stays open with the error, and nothing is written.
      assert has_element?(view, "#location-editor-form")
      assert [%{label: "Our office"}] = reload(view, meeting_type, user).locations
    end
  end

  describe "editing a location" do
    test "replaces it in place, keeping its id and position", %{user: user} = ctx do
      {view, meeting_type} =
        open_editor(ctx, [
          office(),
          %LocationOption{
            id: "loc-call",
            kind: "phone",
            label: "Ring us",
            details: "+44",
            position: 1
          }
        ])

      view
      |> element("[phx-click='edit_location'][phx-value-id='loc-office']")
      |> render_click()

      view
      |> form("#location-editor-form", %{
        "location" => %{
          "kind" => "in_person",
          "label" => "Our new office",
          "details" => "1 Market Square"
        }
      })
      |> render_submit()

      assert [updated, %{label: "Ring us"}] = reload(view, meeting_type, user).locations
      assert updated.id == "loc-office"
      assert updated.position == 0
      assert updated.label == "Our new office"
      assert updated.details == "1 Market Square"
    end
  end

  describe "deleting a location" do
    test "removes it and closes the gap in the ordering", %{user: user} = ctx do
      {view, meeting_type} =
        open_editor(ctx, [
          office(),
          %LocationOption{
            id: "loc-call",
            kind: "phone",
            label: "Ring us",
            details: "+44",
            position: 1
          }
        ])

      view
      |> element("[phx-click='delete_location'][phx-value-id='loc-office']")
      |> render_click()

      assert [remaining] = reload(view, meeting_type, user).locations
      assert remaining.id == "loc-call"
      assert remaining.position == 0
    end
  end
end
