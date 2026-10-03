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

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

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
        assert has_element?(view, "#meeting-type-form-tabs-tab-#{tab}[disabled]")
        refute has_element?(view, "#meeting-type-form-tabs-panel-#{tab}")
      end

      assert has_element?(
               view,
               "#meeting-type-form-create-hint",
               "Create the meeting type to set up the rest."
             )

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

      # Same page and the same form instance, now editing the new type: no
      # navigation happened, the tabs are open and auto-save has taken over.
      :ok = refute_redirected(view)
      assert render(view) =~ "Edit Meeting Type"
      assert has_element?(view, "#meeting-type-form-meeting-type-form-new")
      assert has_element?(view, "form[phx-submit='flush_autosave']")
      refute has_element?(view, "#meeting-type-form-create-hint")

      for tab <- @later_tabs do
        refute has_element?(view, "#meeting-type-form-tabs-tab-#{tab}[disabled]")
      end

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

    test "a forged switch to a disabled tab is ignored while creating", %{conn: conn} do
      view = open_add_form(conn)

      # The tab button is disabled, so send the event straight to the form.
      view
      |> with_target("#meeting-type-form-wrapper-meeting-type-form-new")
      |> render_click("switch_tab", %{"tab" => "booking"})

      assert has_element?(view, "#meeting-type-form-tabs-tab-details[aria-selected='true']")
      refute has_element?(view, "#meeting-type-form-tabs-panel-booking")
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
