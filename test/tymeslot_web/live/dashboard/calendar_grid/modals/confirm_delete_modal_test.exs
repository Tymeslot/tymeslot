defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmDeleteModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmDeleteModal

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        event: %{summary: "Team Standup"},
        deleting: false,
        linked_to_booking: false,
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      },
      overrides
    )
  end

  test "renders delete confirmation with event title" do
    html = render_component(&ConfirmDeleteModal.confirm_delete_modal/1, base_assigns())

    assert html =~ "Delete event"
    assert html =~ "Team Standup"
    assert html =~ "Delete"
    assert html =~ "Cancel"
  end

  test "shows booking warning when linked to booking" do
    html =
      render_component(
        &ConfirmDeleteModal.confirm_delete_modal/1,
        base_assigns(%{linked_to_booking: true})
      )

    assert html =~ "linked to a booking"
    assert html =~ "notified of the cancellation"
  end

  test "hides booking warning when not linked" do
    html = render_component(&ConfirmDeleteModal.confirm_delete_modal/1, base_assigns())

    refute html =~ "linked to a booking"
  end

  test "shows loading state when deleting" do
    html =
      render_component(
        &ConfirmDeleteModal.confirm_delete_modal/1,
        base_assigns(%{deleting: true})
      )

    assert html =~ "Deleting..."
  end

  test "renders no-title placeholder when summary is nil" do
    html =
      render_component(
        &ConfirmDeleteModal.confirm_delete_modal/1,
        base_assigns(%{event: %{summary: nil}})
      )

    assert html =~ "(No title)"
  end

  describe "scopes" do
    test "a series member offers this event or all events" do
      html =
        render_component(
          &ConfirmDeleteModal.confirm_delete_modal/1,
          base_assigns(%{scopes: :series})
        )

      assert html =~ "Delete recurring event"
      assert html =~ "Team Standup"
      assert scope_values(html) == ["occurrence", "series"]
      assert html =~ "Delete this event"
      assert html =~ "Delete all events"
      assert html =~ "Cancel"
    end

    test "a single event offers one Delete without a scope" do
      html = render_component(&ConfirmDeleteModal.confirm_delete_modal/1, base_assigns())

      assert scope_values(html) == []
      refute html =~ "Delete all events"
    end
  end

  defp scope_values(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[phx-click='confirm_delete_event']")
    |> LazyHTML.attribute("phx-value-scope")
  end
end
