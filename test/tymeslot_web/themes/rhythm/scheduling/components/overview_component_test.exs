defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.OverviewComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduledoc """
  Rhythm opens by naming the organiser where Quill opens with a generic
  greeting, so the same stored wording has to displace a different sentence
  here. It also lays the welcome out as two paragraphs rather than one, which is
  where a shared string is most likely to land in the wrong element.
  """
  @moduletag :themes

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Components.OverviewComponent

  describe "introductory text" do
    test "names the organiser in its heading when nothing is customised" do
      html = render_overview(organizer_profile: build(:profile, full_name: "Sarah Rodriguez"))

      assert html =~ "Schedule with Sarah Rodriguez"
      assert html =~ "Hi! I&#39;m Sarah Rodriguez."
      assert html =~ "Pick an option below."
    end

    test "shows the organiser's wording in place of all three lines" do
      profile =
        build(:profile,
          full_name: "Sarah Rodriguez",
          booking_text_enabled: true,
          booking_heading: "Ready to grow your business?",
          booking_greeting: "I am Sarah, and I help teams ship.",
          booking_instruction: "Choose whichever session suits you."
        )

      html = render_overview(organizer_profile: profile)

      assert html =~ "Ready to grow your business?"
      assert html =~ "I am Sarah, and I help teams ship."
      assert html =~ "Choose whichever session suits you."
      refute html =~ "Schedule with Sarah Rodriguez"
      refute html =~ "Pick an option below."
    end

    test "keeps each welcome line in its own paragraph" do
      profile =
        build(:profile,
          booking_text_enabled: true,
          booking_heading: "Book us",
          booking_greeting: "I am Sarah.",
          booking_instruction: "Choose a session."
        )

      html = render_overview(organizer_profile: profile)

      assert html =~ ~r/organizer-greeting[^>]*>\s*I am Sarah\./
      assert html =~ ~r/organizer-instruction[^>]*>\s*Choose a session\./
    end

    test "keeps the theme's wording when the organiser has switched the customisation off" do
      profile =
        build(:profile,
          full_name: "Sarah Rodriguez",
          booking_text_enabled: false,
          booking_heading: "Ready to grow your business?"
        )

      html = render_overview(organizer_profile: profile)

      assert html =~ "Schedule with Sarah Rodriguez"
      refute html =~ "Ready to grow your business?"
    end

    test "escapes wording the organiser typed rather than rendering it as markup" do
      profile =
        build(:profile,
          booking_text_enabled: true,
          booking_heading: "<script>alert(1)</script>",
          booking_greeting: "Hi!",
          booking_instruction: "Pick."
        )

      html = render_overview(organizer_profile: profile)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  defp render_overview(overrides) do
    base = %{
      id: "overview-step",
      locale: "en",
      username_context: "hostuser",
      organizer_profile: build(:profile, full_name: "Sarah Rodriguez"),
      meeting_types: [build(:meeting_type, name: "Discovery Call", duration_minutes: 20)],
      selected_duration: nil
    }

    render_component(OverviewComponent, Map.merge(base, Map.new(overrides)))
  end
end
