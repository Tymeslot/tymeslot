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

  describe "introductory text" do
    test "shows the theme's own wording when the organiser has not customised it" do
      html = render_overview(organizer_profile: build(:profile, full_name: "Sarah Rodriguez"))

      assert html =~ "Let&#39;s Connect!"
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
      refute html =~ "Let&#39;s Connect!"
      refute html =~ "Pick an option below."
    end

    test "keeps the theme's wording when the organiser has switched the customisation off" do
      profile =
        build(:profile,
          full_name: "Sarah Rodriguez",
          booking_text_enabled: false,
          booking_heading: "Ready to grow your business?"
        )

      html = render_overview(organizer_profile: profile)

      assert html =~ "Let&#39;s Connect!"
      refute html =~ "Ready to grow your business?"
    end

    test "drops the greeting rather than render half a sentence for a nameless profile" do
      profile = build(:profile, full_name: nil, user: build(:user, name: nil))

      html = render_overview(organizer_profile: profile)

      assert html =~ "Pick an option below."
      refute html =~ "Hi! I&#39;m"
    end

    test "shows a custom greeting even for a nameless profile" do
      profile =
        build(:profile,
          full_name: nil,
          user: build(:user, name: nil),
          booking_text_enabled: true,
          booking_heading: "Book us",
          booking_greeting: "Hi! We are the support team.",
          booking_instruction: "Pick a slot."
        )

      html = render_overview(organizer_profile: profile)

      assert html =~ "Hi! We are the support team."
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
