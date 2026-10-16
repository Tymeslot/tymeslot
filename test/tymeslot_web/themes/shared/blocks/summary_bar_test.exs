defmodule TymeslotWeb.Themes.Shared.Blocks.SummaryBarTest do
  @moduledoc """
  What the visitor has chosen so far, each item a link back to the moment
  that collected it, found through the journey whatever its moments are
  called.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Themes.Shared.Blocks.SummaryBar
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Moment

  @journey %Journey{
    navigator: nil,
    outcomes: %{},
    moments: [
      %Moment{key: :intro, collects: [], component: nil, defaults: []},
      %Moment{key: :offer, collects: [:meeting_type], component: nil, defaults: []},
      %Moment{key: :when, collects: [:slot], component: nil, defaults: []},
      %Moment{key: :you, collects: [:attendee], component: nil, defaults: []}
    ]
  }

  @meeting_type %MeetingTypeSchema{id: 1, name: "Intro Call", duration_minutes: 30}

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  defp render_bar(overrides) do
    assigns =
      Map.merge(
        %{journey: @journey, meeting_type: nil, user_timezone: "Etc/UTC"},
        Map.new(overrides)
      )

    (&SummaryBar.summary_bar/1)
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  defp text(doc, selector), do: doc |> Floki.find(selector) |> Floki.text() |> String.trim()

  test "renders nothing before a meeting type is chosen" do
    assert Floki.find(render_bar([]), "[data-testid=summary-bar]") == []
  end

  test "names the meeting type and its length, linking to the moment that offered it" do
    doc = render_bar(meeting_type: @meeting_type)

    assert Floki.attribute(doc, "nav[data-testid=summary-bar]", "aria-label") == [
             "Meeting Details"
           ]

    assert text(doc, "[data-testid=summary-bar-meeting-type]") =~ "Intro Call"
    assert text(doc, "[data-testid=summary-bar-meeting-type]") =~ "30 minutes"

    assert Floki.attribute(doc, "[data-testid=summary-bar-meeting-type]", "href") == [
             "#offer-step"
           ]

    assert Floki.find(doc, "[data-testid=summary-bar-slot]") == []
  end

  test "adds the day and time once both are chosen, linking to the moment that took them" do
    doc =
      render_bar(
        meeting_type: @meeting_type,
        selected_date: "2027-03-11",
        selected_time: "10:30 AM"
      )

    assert text(doc, "[data-testid=summary-bar-slot]") =~ "Thursday 11 March"
    assert text(doc, "[data-testid=summary-bar-slot]") =~ "10:30"
    assert Floki.attribute(doc, "[data-testid=summary-bar-slot]", "href") == ["#when-step"]
  end

  test "leaves the slot out while only the day is chosen" do
    doc = render_bar(meeting_type: @meeting_type, selected_date: "2027-03-11")

    assert Floki.find(doc, "[data-testid=summary-bar-slot]") == []
  end
end
