defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

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

  # The scoped choices come back once a provider write honours a scope; until
  # then offering them would promise a change that does not happen.
  test "offers the edit for this event only" do
    html = render_component(&RecurrencePromptModal.recurrence_prompt_modal/1, base_assigns())

    assert html =~ "Edit recurring event"
    assert html =~ ~s(phx-value-scope="this_only")
    assert html =~ "Update this event"
    refute html =~ ~s(phx-value-scope="this_and_following")
    refute html =~ ~s(phx-value-scope="all")
  end

  test "renders cancel button" do
    html = render_component(&RecurrencePromptModal.recurrence_prompt_modal/1, base_assigns())

    assert html =~ "Cancel"
  end
end
