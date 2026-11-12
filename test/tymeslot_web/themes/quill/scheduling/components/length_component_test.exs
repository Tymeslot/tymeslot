defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.LengthComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :themes

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Themes.Quill.Scheduling.Components.LengthComponent

  defp render_length(overrides) do
    base = %{
      id: "length-step",
      locale: "en",
      host_currency: nil,
      username_context: "hostuser",
      organizer_profile: build(:profile, full_name: "Sarah Rodriguez"),
      meeting_type:
        build(:meeting_type,
          name: "Consultation",
          duration_minutes: 30,
          extra_lengths_minutes: [60]
        ),
      selected_duration: nil,
      chosen_length_minutes: nil,
      is_rescheduling: false,
      duration: nil,
      current_step: 1,
      entered_via_overview: nil
    }

    render_component(LengthComponent, Map.merge(base, Map.new(overrides)))
  end

  test "says what is missing while Next is unavailable, linked to the button" do
    html = render_length(chosen_length_minutes: nil)
    doc = Floki.parse_document!(html)

    assert [next] = Floki.find(doc, "[data-testid='next-step']")
    assert Floki.attribute(next, "disabled") != []
    assert Floki.attribute(next, "aria-describedby") == ["next-step-hint"]

    assert doc |> Floki.find("#next-step-hint") |> Floki.text() =~
             "Please select a meeting duration first"
  end

  test "drops the hint once a length is chosen" do
    html = render_length(chosen_length_minutes: 30)

    refute html =~ "Please select a meeting duration first"
  end
end
