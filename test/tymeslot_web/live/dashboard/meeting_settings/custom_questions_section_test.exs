defmodule TymeslotWeb.Dashboard.MeetingSettings.CustomQuestionsSectionTest do
  @moduledoc """
  Integration tests for the custom questions builder inside the meeting type
  form. Covers the host-facing CRUD actions: add, edit, and delete. Drag-and-
  drop reorder requires JS execution and is not exercised here.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :custom_fields
  @moduletag :live
  @moduletag :meeting_types

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  setup :setup_dashboard_user

  # Helper — opens the meeting type form for a given meeting type via the edit
  # action and removes the default reminder so the form's hidden
  # `reminder_config` inputs do not confuse `render_submit/1`.
  defp open_edit_form(view, meeting_type) do
    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    # The form mounts with a default reminder; remove it so the hidden
    # reminder_config inputs don't break form submission (same workaround used
    # throughout meeting_settings_test.exs).
    view |> element("button[aria-label='Remove reminder']") |> render_click()
    view
  end

  describe "adding a custom question" do
    test "question appears in the list after saving the editor", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      assert render(view) =~ "Custom questions"
      assert render(view) =~ "No custom questions yet"

      view |> element("button", "Add question") |> render_click()

      # Editor modal should appear
      assert render(view) =~ "Add question"

      view
      |> form("form[phx-submit='save']", %{
        "definition" => %{"label" => "Company name", "type" => "short_text"}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Company name"
      assert html =~ "Short text"
      refute html =~ "No custom questions yet"
    end

    test "required flag is shown in the list when set", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      view |> element("button", "Add question") |> render_click()

      view
      |> form("form[phx-submit='save']", %{
        "definition" => %{"label" => "Phone number", "type" => "phone", "required" => "true"}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Phone number"
      assert html =~ "required"
    end

    test "validation error shown when label is blank", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      view |> element("button", "Add question") |> render_click()

      view
      |> form("form[phx-submit='save']", %{
        "definition" => %{"label" => "", "type" => "short_text"}
      })
      |> render_submit()

      # The modal should stay open and show the validation error
      assert render(view) =~ "can&#39;t be blank"
    end
  end

  describe "editing a custom question" do
    test "label change is reflected in the list", %{conn: conn, user: user} do
      question_id = Ecto.UUID.generate()

      meeting_type =
        insert(:meeting_type,
          user: user,
          custom_fields: [
            %{
              id: question_id,
              type: "short_text",
              label: "Old label",
              required: false,
              position: 0
            }
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      assert render(view) =~ "Old label"

      view
      |> element("button[phx-click='edit_question'][phx-value-id='#{question_id}']")
      |> render_click()

      assert render(view) =~ "Edit question"

      view
      |> form("form[phx-submit='save']", %{
        "definition" => %{"label" => "New label", "type" => "short_text"}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "New label"
      refute html =~ "Old label"
    end
  end

  describe "deleting a custom question" do
    test "question is removed from the list immediately", %{conn: conn, user: user} do
      question_id = Ecto.UUID.generate()

      meeting_type =
        insert(:meeting_type,
          user: user,
          custom_fields: [
            %{
              id: question_id,
              type: "short_text",
              label: "To be deleted",
              required: false,
              position: 0
            }
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      assert render(view) =~ "To be deleted"

      view
      |> element("button[phx-click='delete_question'][phx-value-id='#{question_id}']")
      |> render_click()

      html = render(view)
      refute html =~ "To be deleted"
      assert html =~ "No custom questions yet"
    end
  end
end
