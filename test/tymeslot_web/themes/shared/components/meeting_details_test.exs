defmodule TymeslotWeb.Themes.Shared.Components.MeetingDetailsTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :themes

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.Themes.Shared.Components.MeetingDetails

  # 09:00 in Kathmandu (UTC+5:45) is stored as 03:15 UTC. Rendering the stored
  # value without shifting shows "03:15 AM" while labelling it Asia/Kathmandu.
  @utc_start DateTime.new!(~D[2026-08-04], ~T[03:15:00], "Etc/UTC")

  defp render_rows(overrides) do
    render_component(
      &MeetingDetails.meeting_detail_rows/1,
      Enum.into(overrides, %{start_time: @utc_start, locale: "en"})
    )
  end

  describe "meeting_detail_rows/1 timezone rendering" do
    test "shows the meeting in the attendee's zone, not UTC" do
      html = render_rows(timezone: "Asia/Kathmandu")

      assert html =~ "09:00 AM"
      assert html =~ "Asia/Kathmandu"
      refute html =~ "03:15 AM"
    end

    test "falls back to the organiser's zone when the attendee's is unknown" do
      html = render_rows(timezone: nil, organizer_profile: %{timezone: "Asia/Kathmandu"})

      assert html =~ "09:00 AM"
      assert html =~ "Asia/Kathmandu"
    end

    test "reads the fallback from an Ecto profile struct, which has no Access" do
      profile = %ProfileSchema{timezone: "Asia/Kathmandu"}

      html = render_rows(timezone: nil, organizer_profile: profile)

      assert html =~ "09:00 AM"
      assert html =~ "Asia/Kathmandu"
    end

    test "the attendee's zone wins over the organiser's" do
      html =
        render_rows(
          timezone: "Asia/Kathmandu",
          organizer_profile: %{timezone: "Europe/Tallinn"}
        )

      assert html =~ "09:00 AM"
      assert html =~ "Asia/Kathmandu"
      refute html =~ "Europe/Tallinn"
    end

    test "labels UTC honestly when no zone is known, rather than claiming one" do
      html = render_rows(timezone: nil, organizer_profile: nil)

      assert html =~ "03:15 AM"
      assert html =~ "Etc/UTC"
    end

    test "an unresolvable zone is labelled with the zone actually rendered" do
      html = render_rows(timezone: "Not/AZone")

      # The value could not be shifted, so it must not claim to be Not/AZone.
      assert html =~ "03:15 AM"
      assert html =~ "Etc/UTC"
      refute html =~ "Not/AZone"
    end
  end
end
