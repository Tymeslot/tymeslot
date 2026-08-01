defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduledoc """
  The Quill overview step must offer the host's own meeting types and nothing
  else. A card for a duration the host never published sends the visitor to a
  slug that resolves to no meeting type, so the booking dead-ends.
  """
  @moduletag :themes

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent

  describe "duration options" do
    test "offers one card per meeting type the host has published" do
      meeting_types = [
        build(:meeting_type, name: "Discovery Call", duration_minutes: 20),
        build(:meeting_type, name: "Deep Dive", duration_minutes: 45)
      ]

      html = render_overview(meeting_types: meeting_types)

      assert html =~ "Discovery Call"
      assert html =~ "Deep Dive"
      assert html =~ ~s(data-duration="discovery-call")
      assert html =~ ~s(data-duration="deep-dive")
      assert duration_option_count(html) == 2
    end

    test "shows the empty state, and no cards at all, when the host published none" do
      html = render_overview(meeting_types: [])

      assert html =~ "No meeting types available"
      assert html =~ "Please contact the organizer"
      assert duration_option_count(html) == 0
    end

    test "never offers a duration the host has not published" do
      meeting_types = [build(:meeting_type, name: "Discovery Call", duration_minutes: 20)]

      html = render_overview(username_context: nil, meeting_types: meeting_types)

      assert html =~ ~s(data-duration="discovery-call")
      refute html =~ ~s(data-duration="15-minutes")
      refute html =~ ~s(data-duration="30-minutes")
      assert duration_option_count(html) == 1
    end
  end

  defp render_overview(overrides) do
    base = %{
      id: "overview-step",
      locale: "en",
      username_context: "hostuser",
      organizer_profile: build(:profile, full_name: "Sarah Rodriguez"),
      meeting_types: [],
      selected_duration: nil
    }

    render_component(OverviewComponent, Map.merge(base, Map.new(overrides)))
  end

  defp duration_option_count(html) do
    html
    |> String.split(~s(data-testid="duration-option"))
    |> length()
    |> Kernel.-(1)
  end
end
