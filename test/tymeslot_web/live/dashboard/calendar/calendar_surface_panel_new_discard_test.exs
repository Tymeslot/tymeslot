defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePanelNewDiscardTest do
  @moduledoc """
  Leaving the side panel's "New event" state: Cancel, the close button and
  opening something else drop the draft from the grid, and while the draft
  has guests who have not been invited yet the panel asks first.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  setup %{conn: conn} do
    context = owner(conn)
    forward_creates(self(), :create)

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")
    Map.merge(context, %{lv: lv})
  end

  describe "a draft with guests" do
    test "asks before Cancel discards it, and Go back keeps it", %{
      lv: lv,
      integration: integration
    } do
      open_panel_draft(lv, integration, %{"guests" => ["grace@example.com", "ada@example.com"]})

      lv |> element("#calendar-panel-new-cancel") |> render_click()

      assert has_element?(
               lv,
               "#calendar-discard-draft",
               "2 guests haven't been invited yet. Discard?"
             )

      assert has_element?(lv, "#calendar-panel")
      # Go back is the one way to keep the draft: no second button says the same.
      refute has_element?(lv, "#calendar-discard-draft button", "Cancel")

      lv |> element("#calendar-discard-draft-cancel", "Go back") |> render_click()

      refute has_element?(lv, "#calendar-discard-draft")
      assert has_element?(lv, "#calendar-panel-guests li", "grace@example.com")
    end

    test "Discard closes the panel and drops the draft", %{lv: lv, integration: integration} do
      open_panel_draft(lv, integration, %{"guests" => ["grace@example.com"]})

      lv |> element("#calendar-panel-close") |> render_click()
      assert has_element?(lv, "#calendar-discard-draft", "1 guest hasn't been invited yet.")

      lv |> element("#calendar-discard-draft-confirm") |> render_click()

      refute has_element?(lv, "#calendar-discard-draft")
      refute has_element?(lv, "#calendar-panel")
      assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
      refute_receive {:provider_call, _pid, _call}, 100
    end

    test "counts a guest typed but not added", %{lv: lv, integration: integration} do
      open_panel_draft(lv, integration)
      render_change(new_event_form(lv), %{"guest_email" => "grace@example.com"})

      lv |> element("#calendar-panel-new-cancel") |> render_click()

      assert has_element?(lv, "#calendar-discard-draft", "1 guest hasn't been invited yet.")
    end

    test "a draft without guests closes at once", %{lv: lv, integration: integration} do
      open_panel_draft(lv, integration)

      lv |> element("#calendar-panel-new-cancel") |> render_click()

      refute has_element?(lv, "#calendar-discard-draft")
      refute has_element?(lv, "#calendar-panel")
    end
  end

  test "the close button drops the draft from the grid", %{lv: lv, integration: integration} do
    open_panel_draft(lv, integration)
    lv |> element("#calendar-panel-close") |> render_click()

    refute has_element?(lv, "#calendar-panel")
    assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
  end

  test "Cancel clears a draft the domain refused on open", %{lv: lv, integration: integration} do
    open_panel_draft(lv, integration, %{"end" => "2026-10-15T12:00"})
    assert has_element?(lv, "#calendar-panel [role=status]", "Couldn't save")

    lv |> element("#calendar-panel-new-cancel") |> render_click()

    assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
  end

  describe "with another event on the grid" do
    setup %{conn: conn, integration: integration} do
      other = event(integration, "work", "Standup", ~U[2026-10-14 09:00:00Z], 30)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      %{lv: lv, other: other}
    end

    test "opening it in the panel asks first while the draft has guests, then opens it", %{
      lv: lv,
      integration: integration,
      other: other
    } do
      open_panel_draft(lv, integration, %{"guests" => ["grace@example.com"]})
      canvas_push(lv, "calendar:edit", %{"id" => "event-#{other.id}"})

      assert has_element?(lv, "#calendar-discard-draft")
      assert has_element?(lv, "#calendar-panel-new-form")

      lv |> element("#calendar-discard-draft-confirm") |> render_click()

      assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
      refute has_element?(lv, "#calendar-panel-new-form")
      assert has_element?(lv, "#calendar-panel")
    end

    test "opening its preview asks first while the draft has guests, and Go back stays", %{
      lv: lv,
      integration: integration,
      other: other
    } do
      open_panel_draft(lv, integration, %{"guests" => ["grace@example.com"]})
      canvas_push(lv, "calendar:open", %{"id" => "event-#{other.id}"})

      assert_reply(lv, %{opened: false})
      assert has_element?(lv, "#calendar-discard-draft")

      lv |> element("#calendar-discard-draft-cancel", "Go back") |> render_click()

      refute has_element?(lv, "#calendar-discard-draft")
      assert has_element?(lv, "#calendar-panel-guests li", "grace@example.com")
    end

    test "opening its preview after Discard shows the preview", %{
      lv: lv,
      integration: integration,
      other: other
    } do
      open_panel_draft(lv, integration, %{"guests" => ["grace@example.com"]})
      canvas_push(lv, "calendar:open", %{"id" => "event-#{other.id}"})
      lv |> element("#calendar-discard-draft-confirm") |> render_click()

      refute has_element?(lv, "#calendar-panel")
      assert has_element?(lv, "#calendar-preview")

      # The hook's open was answered `opened: false`, so it is told to place
      # and focus the preview now.
      id = "event-#{other.id}"
      assert_push_event(lv, "calendar:preview-opened", %{id: ^id})
    end

    test "More options on another draft asks first, then has the hook choose it again", %{
      lv: lv,
      integration: integration
    } do
      open_panel_draft(lv, integration, %{"guests" => ["grace@example.com"]})
      open_panel_draft(lv, integration, %{"draft" => "d2"})

      assert_reply(lv, %{opened: false})
      assert has_element?(lv, "#calendar-discard-draft")

      lv |> element("#calendar-discard-draft-confirm") |> render_click()

      assert_push_event(lv, "calendar:more-options-again", %{draft: "d2"})
      refute has_element?(lv, "#calendar-panel")
    end

    test "opening it in the panel clears the New event draft", %{
      lv: lv,
      integration: integration,
      other: other
    } do
      open_panel_draft(lv, integration)
      canvas_push(lv, "calendar:edit", %{"id" => "event-#{other.id}"})

      assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
      refute has_element?(lv, "#calendar-panel-new-form")
    end

    test "opening its preview clears the New event draft", %{
      lv: lv,
      integration: integration,
      other: other
    } do
      open_panel_draft(lv, integration)
      canvas_push(lv, "calendar:open", %{"id" => "event-#{other.id}"})

      assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
      refute has_element?(lv, "#calendar-panel")
    end
  end

  test "Cancel drops the draft from the grid", %{lv: lv, integration: integration} do
    open_panel_draft(lv, integration)
    lv |> element("#calendar-panel-new-cancel") |> render_click()

    refute has_element?(lv, "#calendar-panel")
    assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
  end
end
