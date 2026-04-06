defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModal

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        recurrence_prompt: %{event_id: "evt-123"},
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      },
      overrides
    )
  end

  test "renders all three scope options" do
    html = render_component(&RecurrencePromptModal.recurrence_prompt_modal/1, base_assigns())

    assert html =~ "Edit recurring event"
    assert html =~ "This event only"
    assert html =~ "This and following events"
    assert html =~ "All events in series"
  end

  test "renders cancel button" do
    html = render_component(&RecurrencePromptModal.recurrence_prompt_modal/1, base_assigns())

    assert html =~ "Cancel"
  end
end
