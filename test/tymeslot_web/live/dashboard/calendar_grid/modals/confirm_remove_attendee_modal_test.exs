defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmRemoveAttendeeModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmRemoveAttendeeModal

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        confirm_remove_attendee: %{email: "alice@example.com"},
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      },
      overrides
    )
  end

  test "renders remove confirmation with attendee email" do
    html =
      render_component(
        &ConfirmRemoveAttendeeModal.confirm_remove_attendee_modal/1,
        base_assigns()
      )

    assert html =~ "Remove attendee"
    assert html =~ "alice@example.com"
    assert html =~ "Remove"
    assert html =~ "Cancel"
  end

  test "shows cancellation warning" do
    html =
      render_component(
        &ConfirmRemoveAttendeeModal.confirm_remove_attendee_modal/1,
        base_assigns()
      )

    assert html =~ "receive a cancellation"
  end
end
