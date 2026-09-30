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
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Venues

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

  defp change_duration(view, minutes) do
    view |> element("[phx-click='switch_tab'][phx-value-tab='details']") |> render_click()

    view
    |> element(~s|input[name="meeting_type[duration]"]|)
    |> render_change(%{"meeting_type" => %{"duration" => minutes}})
  end

  defp office do
    %LocationOption{
      id: "loc-office",
      kind: "in_person",
      label: "Our office",
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
      assert html =~ "Address arranged after booking"
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
      |> form("#location-editor-form", %{"location" => %{"kind" => "custom"}})
      |> render_change()

      view
      |> form("#location-editor-form", %{
        "location" => %{
          "kind" => "custom",
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
          "video_integration_ids" => [to_string(integration.id)]
        }
      })
      |> render_submit()

      reloaded = reload(view, meeting_type, user)

      assert [_office, video] = reloaded.locations
      assert video.kind == "video"
      assert video.video_integration_ids == [integration.id]

      # The pair every pre-list reader still consults is projected from it.
      assert reloaded.allow_video == true
      assert reloaded.video_integration_id == integration.id
    end

    test "offers the kinds as toggles with the current one checked", ctx do
      {view, _meeting_type} = open_editor(ctx, [office()])

      view |> element("button[data-testid='add-location']") |> render_click()

      assert has_element?(view, "#location_kind input[type='radio'][value='in_person'][checked]")
      refute has_element?(view, "#location_kind input[value='video'][checked]")

      view
      |> form("#location-editor-form", %{"location" => %{"kind" => "video"}})
      |> render_change()

      assert has_element?(view, "#location_kind input[value='video'][checked]")
      refute has_element?(view, "#location_kind input[value='in_person'][checked]")
    end

    test "a video location can offer several providers for the booker to pick from",
         %{user: user} = ctx do
      zoom = insert(:video_integration, user: user, name: "Zoom", is_active: true)
      teams = insert(:video_integration, user: user, name: "Teams", is_active: true)
      {view, meeting_type} = open_editor(ctx, [office()])

      view |> element("button[data-testid='add-location']") |> render_click()

      view
      |> form("#location-editor-form", %{"location" => %{"kind" => "video"}})
      |> render_change()

      view
      |> form("#location-editor-form", %{
        "location" => %{
          "kind" => "video",
          "label" => "Video call",
          "video_integration_ids" => ["", to_string(zoom.id), to_string(teams.id)]
        }
      })
      |> render_submit()

      reloaded = reload(view, meeting_type, user)

      assert [_office, video] = reloaded.locations
      assert video.video_integration_ids == [zoom.id, teams.id]
      assert reloaded.video_integration_id == zoom.id
    end

    test "tells two same-named integrations apart by their account", %{user: user} = ctx do
      insert(:video_integration,
        user: user,
        name: "Zoom",
        provider_account_email: "sales@example.com",
        is_active: true
      )

      insert(:video_integration,
        user: user,
        name: "Zoom",
        provider_account_email: "support@example.com",
        is_active: true
      )

      insert(:video_integration, user: user, name: "Team Room", is_active: true)
      {view, _meeting_type} = open_editor(ctx, [office()])

      view |> element("button[data-testid='add-location']") |> render_click()

      view
      |> form("#location-editor-form", %{"location" => %{"kind" => "video"}})
      |> render_change()

      labels =
        view
        |> element("#location_video_integration_ids")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("[data-testid='location_video_integration_ids-option']")
        |> Enum.map(&String.trim(Floki.text(&1)))
        |> Enum.sort()

      assert labels == ["Team Room", "Zoom (sales@example.com)", "Zoom (support@example.com)"]
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

  describe "an in-person location's saved locations" do
    test "names the saved location it offers in the list", %{user: user} = ctx do
      berlin =
        insert(:venue, user: user, name: "Berlin office", description: "Friedrichstrasse 1")

      {view, _type} = open_editor(ctx, [%{office() | venue_ids: [berlin.id]}])

      assert render(view) =~ "Berlin office (Friedrichstrasse 1)"
    end

    test "offers the organiser's saved locations and stores the ones ticked",
         %{user: user} = ctx do
      berlin = insert(:venue, user: user, name: "Berlin office")
      munich = insert(:venue, user: user, name: "Munich office")
      {view, meeting_type} = open_editor(ctx, [office()])

      view
      |> element("[phx-click='edit_location'][phx-value-id='loc-office']")
      |> render_click()

      offered =
        view
        |> element("#location_venue_ids")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("[data-testid='location_venue_ids-option']")
        |> Enum.map(&String.trim(Floki.text(&1)))

      assert offered == ["Berlin office", "Munich office"]

      view
      |> form("#location-editor-form", %{
        "location" => %{
          "kind" => "in_person",
          "label" => "Our offices",
          "venue_ids" => ["", to_string(berlin.id), to_string(munich.id)]
        }
      })
      |> render_submit()

      assert [offices] = reload(view, meeting_type, user).locations
      assert offices.venue_ids == [berlin.id, munich.id]
      assert offices.label == "Our offices"
    end

    test "a location that offered a deleted one does not stop the meeting type saving",
         %{user: user} = ctx do
      berlin = insert(:venue, user: user, name: "Berlin office")
      gone = insert(:venue, user: user, name: "Closed office")
      # Deleting through `Venues` would also rewrite the meeting type, so this
      # removes the row directly: it guards a mismatch between the library and
      # a location's ids, not a path the product takes.
      Repo.delete!(gone)

      {view, meeting_type} =
        open_editor(ctx, [
          %{office() | venue_ids: [gone.id, berlin.id]},
          %LocationOption{
            id: "loc-call",
            kind: "phone",
            label: "Ring us",
            details: "+44",
            position: 1
          }
        ])

      # Saving the other location saves the whole list, the office included.
      view
      |> element("[phx-click='edit_location'][phx-value-id='loc-call']")
      |> render_click()

      view
      |> form("#location-editor-form", %{"location" => %{"label" => "Call us"}})
      |> render_submit()

      assert [offices, call] = reload(view, meeting_type, user).locations
      assert call.label == "Call us"
      assert offices.venue_ids == [berlin.id]
    end

    test "an open form keeps saving after a location it offers is deleted elsewhere",
         %{user: user} = ctx do
      berlin = insert(:venue, user: user, name: "Berlin office")
      munich = insert(:venue, user: user, name: "Munich office")
      {view, meeting_type} = open_editor(ctx, [%{office() | venue_ids: [berlin.id, munich.id]}])

      # From the Locations page in another tab, while this form stays open.
      {:ok, _deleted} = Venues.delete_venue(berlin)

      change_duration(view, "45")

      reloaded = reload(view, meeting_type, user)
      assert reloaded.duration_minutes == 45
      assert [%{venue_ids: [munich_id]}] = reloaded.locations
      assert munich_id == munich.id
      assert has_element?(view, "span", "All changes saved")

      view |> element("[phx-click='switch_tab'][phx-value-tab='location']") |> render_click()
      assert has_element?(view, "[data-testid='location-row']", "Munich office")
      refute render(view) =~ "Berlin office"
    end

    test "an open form keeps saving after the only location it offers is deleted elsewhere",
         %{user: user} = ctx do
      berlin = insert(:venue, user: user, name: "Berlin office")
      {view, meeting_type} = open_editor(ctx, [%{office() | venue_ids: [berlin.id]}])

      {:ok, _deleted} = Venues.delete_venue(berlin)

      change_duration(view, "45")

      reloaded = reload(view, meeting_type, user)
      assert reloaded.duration_minutes == 45
      assert [%{venue_ids: []}] = reloaded.locations

      view |> element("[phx-click='switch_tab'][phx-value-tab='location']") |> render_click()
      assert has_element?(view, "[data-testid='location-row']", "Address arranged after booking")
    end

    test "creating a meeting type goes through after a location it offers is deleted elsewhere",
         %{conn: conn, user: user} do
      berlin = insert(:venue, user: user, name: "Berlin office")
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view |> element("button", "Add Meeting Type") |> render_click()
      # The default reminder's hidden inputs cannot be re-encoded by
      # `form/3`; see the creation test in `MeetingSettingsTest`.
      view |> element("button[aria-label='Remove reminder']") |> render_click()
      view |> element("[phx-click='edit_location']") |> render_click()

      view
      |> form("#location-editor-form", %{
        "location" => %{"venue_ids" => ["", to_string(berlin.id)]}
      })
      |> render_submit()

      _drain = :sys.get_state(view.pid)
      {:ok, _deleted} = Venues.delete_venue(berlin)

      view
      |> form("form[phx-submit='save_meeting_type']", %{
        "meeting_type" => %{"name" => "Site visit", "duration" => "20"}
      })
      |> render_submit()

      assert render(view) =~ "Meeting type created"

      assert [%{locations: [%{venue_ids: []}]}] =
               user.id
               |> MeetingTypes.get_all_meeting_types()
               |> Enum.filter(&(&1.name == "Site visit"))
    end

    test "says when no address is selected", %{user: user} = ctx do
      berlin = insert(:venue, user: user, name: "Berlin office")
      {view, _meeting_type} = open_editor(ctx, [office()])

      view
      |> element("[phx-click='edit_location'][phx-value-id='loc-office']")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid='venue-hint']",
               "No address selected: bookers are told it will be arranged after booking."
             )

      view
      |> form("#location-editor-form", %{
        "location" => %{"venue_ids" => ["", to_string(berlin.id)]}
      })
      |> render_change()

      refute has_element?(view, "[data-testid='venue-hint']")
    end

    test "+ New location creates a location and selects it without leaving the form",
         %{user: user} = ctx do
      {view, meeting_type} = open_editor(ctx, [office()])

      view
      |> element("[phx-click='edit_location'][phx-value-id='loc-office']")
      |> render_click()

      view |> element("[data-testid='new-venue-toggle']") |> render_click()

      view
      |> form("#new-venue-form", %{
        "venue" => %{"name" => "Studio", "description" => "Canal Street 5"}
      })
      |> render_submit()

      _drain = :sys.get_state(view.pid)

      assert [studio] = Venues.list_venues(user.id)
      assert studio.description == "Canal Street 5"
      assert has_element?(view, "#location_venue_ids input[value='#{studio.id}'][checked]")
      assert has_element?(view, "#location-editor-form")
      refute has_element?(view, "#new-venue-form")

      view |> form("#location-editor-form") |> render_submit()

      assert [location] = reload(view, meeting_type, user).locations
      assert location.venue_ids == [studio.id]
      # The page's own venue list has the new one too, so it is named here.
      assert render(view) =~ "Studio (Canal Street 5)"
    end

    test "+ New location does not make later edits to the meeting type go unsaved",
         %{user: user} = ctx do
      {view, meeting_type} = open_editor(ctx, [office()])
      duration = ~s|input[name="meeting_type[duration]"]|

      view |> element("[phx-click='switch_tab'][phx-value-tab='details']") |> render_click()
      view |> element(duration) |> render_change(%{"meeting_type" => %{"duration" => "45"}})
      assert reload(view, meeting_type, user).duration_minutes == 45

      view |> element("[phx-click='switch_tab'][phx-value-tab='location']") |> render_click()

      view
      |> element("[phx-click='edit_location'][phx-value-id='loc-office']")
      |> render_click()

      view |> element("[data-testid='new-venue-toggle']") |> render_click()
      view |> form("#new-venue-form", %{"venue" => %{"name" => "Studio"}}) |> render_submit()
      _drain = :sys.get_state(view.pid)
      view |> element("button[phx-click='cancel']", "Cancel") |> render_click()

      # Back to the value the editor was opened with: the page reloaded when
      # the location was created, and must not have handed the form that
      # older version to save against.
      view |> element("[phx-click='switch_tab'][phx-value-tab='details']") |> render_click()
      view |> element(duration) |> render_change(%{"meeting_type" => %{"duration" => "30"}})

      assert reload(view, meeting_type, user).duration_minutes == 30
    end

    test "+ New location keeps the form open with the error for a name already used",
         %{user: user} = ctx do
      insert(:venue, user: user, name: "Studio")
      {view, _meeting_type} = open_editor(ctx, [office()])

      view
      |> element("[phx-click='edit_location'][phx-value-id='loc-office']")
      |> render_click()

      view |> element("[data-testid='new-venue-toggle']") |> render_click()

      html =
        view
        |> form("#new-venue-form", %{"venue" => %{"name" => "Studio"}})
        |> render_submit()

      assert html =~ "has already been taken"
      assert has_element?(view, "#new-venue-form")
      assert [_only] = Venues.list_venues(user.id)
    end

    test "+ New location is refused over the meeting-type write limit", %{user: user} = ctx do
      {view, _meeting_type} = open_editor(ctx, [office()])

      view
      |> element("[phx-click='edit_location'][phx-value-id='loc-office']")
      |> render_click()

      view |> element("[data-testid='new-venue-toggle']") |> render_click()

      message =
        Enum.find_value(
          Stream.repeatedly(fn -> RateLimiter.check_meeting_type_write_rate_limit(user.id) end),
          fn
            {:error, :rate_limited, message} -> message
            :ok -> nil
          end
        )

      view |> form("#new-venue-form", %{"venue" => %{"name" => "Studio"}}) |> render_submit()
      _drain = :sys.get_state(view.pid)

      assert Venues.list_venues(user.id) == []
      assert has_element?(view, "#new-venue-form")
      assert has_element?(view, "#app-flash-group-error", message)
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
        "location" => %{"kind" => "in_person", "label" => "Our new office"}
      })
      |> render_submit()

      assert [updated, %{label: "Ring us"}] = reload(view, meeting_type, user).locations
      assert updated.id == "loc-office"
      assert updated.position == 0
      assert updated.label == "Our new office"
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
