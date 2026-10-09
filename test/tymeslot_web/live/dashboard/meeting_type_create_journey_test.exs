defmodule TymeslotWeb.Dashboard.MeetingTypeCreateJourneyTest do
  @moduledoc """
  The journey from "Add meeting type" to a configured meeting type.

  Adding uses the same tabbed form as editing. Auto-save needs a record to
  save into, so a new type opens on Details with the other tabs disabled and
  one explicit "Create meeting type" action; once created, the same form
  instance switches to editing the new record in place and auto-save takes
  over for the rest.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :integration
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Phoenix.LiveView
  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm

  setup :setup_dashboard_user

  # The hint explaining the disabled tabs, scoped to the new-type form's id.
  @hint_id "meeting-type-form-meeting-type-form-new-create-hint"

  # The tabs that need a saved record.
  @later_tabs ~w(location booking questions reminders)

  defp open_add_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    view |> element("button", "Add Meeting Type") |> render_click()
    view
  end

  defp created_type(user, name),
    do: Enum.find(MeetingTypes.get_all_meeting_types(user.id), &(&1.name == name))

  describe "Creating a meeting type" do
    test "creates on the Details tab, then carries on in place as the editor", %{
      conn: conn,
      user: user
    } do
      view = open_add_form(conn)

      # The same tabbed form as editing, opened on Details, with the tabs that
      # need a saved record shown but disabled and the reason given.
      assert has_element?(view, "#meeting-type-form-tabs-tab-details[aria-selected='true']")
      refute has_element?(view, "#meeting-type-form-tabs-tab-details[disabled]")

      for tab <- @later_tabs do
        # Each disabled tab points screen readers at the hint saying why.
        assert has_element?(
                 view,
                 "#meeting-type-form-tabs-tab-#{tab}[disabled][aria-describedby='#{@hint_id}']"
               )

        refute has_element?(view, "#meeting-type-form-tabs-panel-#{tab}")
      end

      refute has_element?(view, "#meeting-type-form-tabs-tab-details[aria-describedby]")
      assert has_element?(view, "##{@hint_id}", "Create the meeting type to set up the rest.")

      assert has_element?(view, "button[type='submit']", "Create meeting type")
      refute has_element?(view, "button", "Done")

      # Filling in Details saves nothing yet: there is no record to save into.
      view
      |> element(~s|input[name="meeting_type[name]"]|)
      |> render_change(%{"meeting_type" => %{"name" => "Quick Coffee"}})

      view
      |> element(~s|input[name="meeting_type[duration]"]|)
      |> render_change(%{"meeting_type" => %{"duration" => "20"}})

      assert is_nil(created_type(user, "Quick Coffee"))

      view |> form("form[phx-submit='create_meeting_type']") |> render_submit()

      created = created_type(user, "Quick Coffee")
      assert created.duration_minutes == 20
      assert render(view) =~ "Meeting type created"

      # The pressed "Create" button is gone, so focus moves to the selected
      # tab rather than falling back to the page body.
      assert_push_event(view, "focus", %{id: "meeting-type-form-tabs-tab-details"})
      assert has_element?(view, "#meeting-type-form-tabs-tab-details[aria-selected='true']")

      # Same page and the same form instance, now editing the new type: no
      # navigation happened, the tabs are open and auto-save has taken over.
      :ok = refute_redirected(view)
      assert render(view) =~ "Edit Meeting Type"
      assert has_element?(view, "#meeting-type-form-meeting-type-form-new")
      assert has_element?(view, "form[phx-submit='flush_autosave']")
      refute has_element?(view, "##{@hint_id}")

      for tab <- @later_tabs do
        refute has_element?(view, "#meeting-type-form-tabs-tab-#{tab}[disabled]")
      end

      refute has_element?(view, "#meeting-type-form-tabs [aria-describedby]")

      # Carry on to another tab; a change there auto-saves.
      view |> element("#meeting-type-form-tabs-tab-booking") |> render_click()
      refute has_element?(view, "#meeting-type-form-tabs-panel-booking[hidden]")
      refute MeetingTypes.get_meeting_type(created.id, user.id).allow_guests

      view |> element("#allow-guests-toggle") |> render_click()

      assert MeetingTypes.get_meeting_type(created.id, user.id).allow_guests
      assert has_element?(view, "[aria-live='polite']", "All changes saved")

      # Done returns to the list, which shows the new type.
      view |> element("button", "Done") |> render_click()

      refute has_element?(view, "#meeting-type-config-view")
      assert has_element?(view, "h2", "Quick Coffee")

      assert length(
               Enum.filter(
                 MeetingTypes.get_all_meeting_types(user.id),
                 &(&1.name == "Quick Coffee")
               )
             ) == 1
    end

    test "validation errors stay on Details and nothing is created", %{conn: conn, user: user} do
      before = length(MeetingTypes.get_all_meeting_types(user.id))
      view = open_add_form(conn)

      view
      |> form("form[phx-submit='create_meeting_type']", %{
        "meeting_type" => %{"name" => "", "duration" => "20"}
      })
      |> render_submit()

      assert length(MeetingTypes.get_all_meeting_types(user.id)) == before

      # The Create button is still there holding focus, so it is not moved.
      refute_push_event(view, "focus", %{})

      # Still creating, on Details, with the error beside the field.
      assert has_element?(view, "#meeting-type-form-tabs-tab-details[aria-selected='true']")
      refute has_element?(view, "#meeting-type-form-tabs-panel-details[hidden]")

      assert has_element?(
               view,
               "#meeting-type-form-tabs-tab-details span",
               "This tab contains errors"
             )

      assert has_element?(
               view,
               ~s|#meeting-type-form-tabs-panel-details input.input-error[name="meeting_type[name]"]|
             )

      assert has_element?(view, "button[type='submit']", "Create meeting type")
      assert has_element?(view, "#meeting-type-form-tabs-tab-booking[disabled]")
    end

    test "a name the host already uses is refused beside the name field", %{
      conn: conn,
      user: user
    } do
      insert(:meeting_type, user: user, name: "Weekly Sync")
      before = length(MeetingTypes.get_all_meeting_types(user.id))
      view = open_add_form(conn)

      view
      |> form("form[phx-submit='create_meeting_type']", %{
        "meeting_type" => %{"name" => "Weekly Sync", "duration" => "20"}
      })
      |> render_submit()

      assert length(MeetingTypes.get_all_meeting_types(user.id)) == before

      assert has_element?(
               view,
               ~s|#meeting-type-form-tabs-panel-details input.input-error[name="meeting_type[name]"]|
             )

      assert has_element?(
               view,
               "#meeting-type-form-tabs-panel-details",
               "You already have a meeting type with this name"
             )
    end

    test "a forged switch to a disabled tab is ignored while creating", %{conn: conn} do
      view = open_add_form(conn)

      # The tab button is disabled, so send the event straight to the form.
      view
      |> with_target("#meeting-type-form-wrapper-meeting-type-form-new")
      |> render_click("switch_tab", %{"tab" => "booking"})

      assert has_element?(view, "#meeting-type-form-tabs-tab-details[aria-selected='true']")
      refute has_element?(view, "#meeting-type-form-tabs-panel-booking")
    end

    # No test covers a video integration deactivated while the create form is
    # open: the create cannot reference one. Video integrations are chosen per
    # location, and until the record exists the Location panel is not rendered
    # (forged tab switches are ignored, as above), so creation always posts the
    # default in-person location with no video integration ids, and
    # `allow_video`/`video_integration_id` are projected from those locations
    # rather than posted.

    test "a second create submit after the first has landed is ignored", %{
      conn: conn,
      user: user
    } do
      view = open_add_form(conn)

      view
      |> form("form[phx-submit='create_meeting_type']", %{
        "meeting_type" => %{"name" => "Double Click", "duration" => "30"}
      })
      |> render_submit()

      # A double click: the second submit reaches the form after it has
      # already switched to editing the new type.
      view
      |> with_target("#meeting-type-form-wrapper-meeting-type-form-new")
      |> render_submit("create_meeting_type", %{
        "meeting_type" => %{"name" => "Double Click", "duration" => "30"}
      })

      assert Process.alive?(view.pid)
      assert has_element?(view, "form[phx-submit='flush_autosave']")

      assert user.id
             |> MeetingTypes.get_all_meeting_types()
             |> Enum.count(&(&1.name == "Double Click")) == 1
    end

    test "stale new-type props arriving after creation leave the form editing", %{
      conn: conn,
      user: user
    } do
      view = open_add_form(conn)

      view
      |> form("form[phx-submit='create_meeting_type']", %{
        "meeting_type" => %{"name" => "Stale Props", "duration" => "30"}
      })
      |> render_submit()

      # The parent rendering once more with the props it had while the type
      # was new, before it has heard about the record.
      LiveView.send_update(view.pid, MeetingTypeForm,
        id: "meeting-type-form-new",
        type: nil,
        is_edit: false
      )

      assert has_element?(view, "form[phx-submit='flush_autosave']")
      refute has_element?(view, "#meeting-type-form-tabs-tab-booking[disabled]")
      assert %{name: "Stale Props"} = created_type(user, "Stale Props")
    end

    test "choosing \"Custom…\" as the interval does not block creating", %{
      conn: conn,
      user: user
    } do
      view = open_add_form(conn)

      # The dropdown's custom entry names a mode, not an interval, so it must
      # not reach validation as one.
      view
      |> form("form[phx-submit='create_meeting_type']", %{
        "meeting_type" => %{
          "name" => "Custom Interval",
          "duration" => "30",
          "slot_interval" => "custom"
        }
      })
      |> render_submit()

      assert %{slot_interval_minutes: nil} = created_type(user, "Custom Interval")
    end

    test "cancel returns to the list without creating anything", %{conn: conn, user: user} do
      before = length(MeetingTypes.get_all_meeting_types(user.id))
      view = open_add_form(conn)

      view |> element("button[phx-click='toggle_add_form']", "Cancel") |> render_click()

      refute has_element?(view, "#meeting-type-config-view")
      assert length(MeetingTypes.get_all_meeting_types(user.id)) == before
    end
  end
end
