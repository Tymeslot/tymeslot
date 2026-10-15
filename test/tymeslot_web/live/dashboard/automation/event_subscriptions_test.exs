defmodule TymeslotWeb.Dashboard.Automation.EventSubscriptionsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :automation
  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.Automation.EventSubscriptions

  @events [
    %{value: "meeting.created", label: "Meeting created", description: "A booking is made"},
    %{
      value: "meeting.cancelled",
      label: "Meeting cancelled",
      description: "A booking is cancelled"
    }
  ]

  defp render_card(overrides \\ []) do
    html =
      render_component(
        &EventSubscriptions.event_subscriptions/1,
        Enum.into(overrides, %{
          name: "slack[events][]",
          events: @events,
          selected: ["meeting.cancelled"],
          toggle_event: "slack_toggle_event",
          target: "#automation",
          description: "Select which events should trigger Slack notifications."
        })
      )

    {html, Floki.parse_document!(html)}
  end

  test "renders the heading, the description and each event's label and meaning" do
    {html, _doc} = render_card()

    assert html =~ "Event Subscriptions"
    assert html =~ "Select which events should trigger Slack notifications."
    assert html =~ "Meeting created"
    assert html =~ "A booking is made"
    assert html =~ "Meeting cancelled"
    assert html =~ "A booking is cancelled"
  end

  test "submits each event under the given name, ticking only the selected ones" do
    {_html, doc} = render_card()

    boxes = Floki.find(doc, "input[type='checkbox'][name='slack[events][]']")

    assert Enum.map(boxes, &(&1 |> Floki.attribute("value") |> hd())) ==
             ["meeting.created", "meeting.cancelled"]

    assert Floki.attribute(doc, "input[type='checkbox'][checked]", "value") == [
             "meeting.cancelled"
           ]
  end

  test "pushes the toggle event with the event's value to the target" do
    {_html, doc} = render_card()

    [created | _rest] = Floki.find(doc, "input[type='checkbox'][name='slack[events][]']")
    [click] = Floki.attribute(created, "phx-click")

    assert [
             [
               "push",
               %{"event" => "slack_toggle_event", "target" => "#automation", "value" => value}
             ]
           ] =
             Jason.decode!(click)

    assert value == %{"event" => "meeting.created"}
  end

  test "lists each error under the events" do
    {_html, doc} = render_card(errors: ["Select at least one event", "Another problem"])

    assert doc |> Floki.find("p.text-red-600") |> Enum.map(&Floki.text/1) ==
             ["Select at least one event", "Another problem"]
  end

  test "renders no error line without errors" do
    {_html, doc} = render_card()

    assert Floki.find(doc, "p.text-red-600") == []
  end
end
