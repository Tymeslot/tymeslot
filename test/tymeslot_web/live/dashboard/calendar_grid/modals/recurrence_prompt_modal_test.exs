defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModal

  defp render_prompt(prompt) do
    render_component(&RecurrencePromptModal.recurrence_prompt_modal/1, %{
      recurrence_prompt: prompt,
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    })
  end

  defp scope_buttons(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("button[phx-value-scope]")
    |> Enum.map(fn button ->
      [scope] = LazyHTML.attribute(button, "phx-value-scope")
      {scope, String.trim(LazyHTML.text(button))}
    end)
  end

  test "a change of time offers this event, this and following, and all events, in order" do
    html = render_prompt(%{event_id: "evt-123"})

    assert html =~ "Edit recurring event"

    assert scope_buttons(html) == [
             {"this_only", "This event"},
             {"following", "This and following events"},
             {"all", "All events"}
           ]
  end

  test "says what each choice changes" do
    html = render_prompt(%{event_id: "evt-123"})

    assert html =~ "only this occurrence changes"
    assert html =~ "this occurrence and every later one change"
    assert html =~ "every occurrence in the series changes"
  end

  # One occurrence cannot take a repeat rule of its own.
  test "a change of repeat rule is not offered for this event alone" do
    html = render_prompt(%{kind: :recurrence_rule})

    assert scope_buttons(html) == [
             {"following", "This and following events"},
             {"all", "All events"}
           ]

    refute html =~ "only this occurrence changes"
  end

  test "renders cancel button" do
    assert render_prompt(%{event_id: "evt-123"}) =~ "Cancel"
  end
end
