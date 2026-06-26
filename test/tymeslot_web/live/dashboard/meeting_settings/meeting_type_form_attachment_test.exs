defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeFormAttachmentTest do
  @moduledoc """
  Integration tests for the meeting-type attachment upload journey.

  These tests pin the fix for the nested-form bug: the attachment upload
  `<form id="attachment-upload-form">` is rendered OUTSIDE the outer
  meeting-type `<form>`, so its `phx-change`/`phx-submit` events fire.
  If the form were ever moved back inside the outer form, HTML5 would
  silently discard the nested form and the events would stop firing —
  these tests would fail at the `render_submit` step, making the
  regression immediately visible.

  Covers the live events on `MeetingTypeForm`:
    1. `upload_attachment` — file appears in the list and is persisted.
    2. `remove_attachment` — file disappears from the list and is removed
       from the database.
    3. `toggle_show_as_free` — checkbox flips in the rendered HTML.

  `async: false`: writes to the shared test upload directory and exercises
  the autosave rate-limiter bucket (global per user-id).
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live
  @moduletag :integration

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  # Minimal PDF content. AttachmentUpload validates extension and size only —
  # no magic-bytes check — so any non-empty binary with a .pdf name passes.
  @pdf_content "%PDF-1.4\n1 0 obj\n<</Type/Catalog>>\nendobj\n%%EOF"

  defp pdf_upload do
    %{
      last_modified: System.system_time(:millisecond),
      name: "brief.pdf",
      content: @pdf_content,
      type: "application/pdf"
    }
  end

  # Opens the edit overlay for the given meeting type and asserts it rendered.
  defp open_edit_form(view, meeting_type) do
    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    assert render(view) =~ "Edit Meeting Type"
  end

  # ---------------------------------------------------------------------------
  # Upload
  # ---------------------------------------------------------------------------

  describe "upload_attachment event" do
    @tag :capture_log
    test "uploading a .pdf via the attachment form adds it to the list and persists it",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Upload Test")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      # The attachment upload form must be present (i.e. rendered outside the
      # outer meeting-type form — the bug this test pins).
      assert has_element?(view, "#attachment-upload-form")

      view
      |> file_input("#attachment-upload-form", :attachment, [pdf_upload()])
      |> render_upload("brief.pdf")

      # Submitting the form fires phx-submit="upload_attachment" on the
      # MeetingTypeForm LiveComponent, which calls consume_uploaded_entries.
      view
      |> form("#attachment-upload-form")
      |> render_submit()

      html = render(view)
      assert html =~ "brief.pdf"

      reloaded = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
      assert length(reloaded.attachments) == 1
      assert hd(reloaded.attachments).filename == "brief.pdf"
    end
  end

  # ---------------------------------------------------------------------------
  # Remove
  # ---------------------------------------------------------------------------

  describe "remove_attachment event" do
    @tag :capture_log
    test "clicking Remove removes the attachment from the list and the database",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Remove Test")

      # Pre-populate via the domain — setup state, not the action under test.
      # stored_path points to a non-existent file; safe_delete_file handles
      # :enoent gracefully (it logs and returns :ok).
      {:ok, meeting_type} =
        MeetingTypes.add_attachment(meeting_type, %{
          "filename" => "agenda.pdf",
          "stored_path" => "attachments/test_placeholder/agenda.pdf",
          "content_type" => "application/pdf",
          "byte_size" => 512
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      assert render(view) =~ "agenda.pdf"

      attachment_id = hd(meeting_type.attachments).id

      view
      |> element("button[phx-click='remove_attachment'][phx-value-id='#{attachment_id}']")
      |> render_click()

      refute render(view) =~ "agenda.pdf"

      reloaded = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
      assert reloaded.attachments == []
    end
  end

  # ---------------------------------------------------------------------------
  # Toggle show_as_free
  # ---------------------------------------------------------------------------

  describe "toggle_show_as_free event" do
    test "toggling the calendar-availability checkbox flips the rendered state",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Toggle Test")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      # meeting_type_factory defaults show_as_free to false.
      refute has_element?(view, ~s|input[phx-click="toggle_show_as_free"][checked]|)

      view
      |> element(~s|input[phx-click="toggle_show_as_free"]|)
      |> render_click()

      # The socket assign flips and the checkbox re-renders as checked.
      assert has_element?(view, ~s|input[phx-click="toggle_show_as_free"][checked]|)

      # Auto-save ran — indicator must show success, not an error.
      assert render(view) =~ "All changes saved"
    end
  end
end
