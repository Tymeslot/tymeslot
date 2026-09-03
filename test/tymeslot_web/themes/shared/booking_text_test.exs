defmodule TymeslotWeb.Themes.Shared.BookingTextTest do
  use TymeslotWeb.ConnCase, async: true

  @moduledoc """
  One organiser's wording has to reach every theme, and the switch that turns it
  on has to be the only thing that decides whether a visitor sees it. Stored
  wording with the switch off is wording the organiser has retired, not wording
  the page should still be showing.
  """
  @moduletag :themes
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.Themes.Shared.BookingText

  describe "custom wording" do
    test "reaches both themes from the one profile field" do
      profile = customized(booking_heading: "Let's build something")

      assert BookingText.heading(profile, :quill, "Sam") == "Let's build something"
      assert BookingText.heading(profile, :rhythm, "Sam") == "Let's build something"
    end

    test "is ignored while the customisation is switched off" do
      profile =
        build(:profile,
          booking_text_enabled: false,
          booking_heading: "Let's build something",
          booking_greeting: "Hi! I'm Sam.",
          booking_instruction: "Pick a slot."
        )

      assert BookingText.heading(profile, :quill, "Sam") ==
               BookingText.default_heading(:quill, "Sam")

      assert BookingText.greeting(profile, "Sam") == BookingText.default_greeting("Sam")
      assert BookingText.instruction(profile) == BookingText.default_instruction()
    end

    test "replaces the greeting even when the profile has no name to introduce" do
      profile = customized(booking_greeting: "Hi! I'm the team.")

      assert BookingText.greeting(profile, nil) == "Hi! I'm the team."
    end

    test "customized? reports the switch, not the presence of stored wording" do
      assert BookingText.customized?(customized(booking_heading: "x"))
      refute BookingText.customized?(build(:profile, booking_heading: "x"))
      refute BookingText.customized?(nil)
    end
  end

  describe "defaults" do
    test "differ per theme, which is what the dashboard has to show an organiser" do
      quill = BookingText.default_heading(:quill, "Sam")
      rhythm = BookingText.default_heading(:rhythm, "Sam")

      refute quill == rhythm
      assert rhythm =~ "Sam"
      refute quill =~ "Sam"
    end

    test "drop the greeting rather than render half a sentence with no name" do
      assert BookingText.default_greeting(nil) == nil
      assert BookingText.default_greeting("Sam") =~ "Sam"
    end

    test "seed a greeting even for a nameless profile, which the default drops" do
      # The switch writes all three lines at once, so a profile with no name
      # still needs something to start from; "on but blank" is a state the
      # changeset refuses and a form with no save button could never leave.
      # Asserting through the changeset is the point: a seed the changeset
      # rejects would strand the switch, whatever its type.
      assert BookingText.default_greeting(nil) == nil

      changeset =
        ProfileSchema.booking_text_changeset(%ProfileSchema{}, %{
          "booking_text_enabled" => true,
          "booking_heading" => BookingText.default_heading(:quill, nil),
          "booking_greeting" => BookingText.seed_greeting(nil),
          "booking_instruction" => BookingText.default_instruction()
        })

      assert changeset.valid?
      assert BookingText.seed_greeting("Sam") == BookingText.default_greeting("Sam")
    end

    test "fall back to the generic heading for a theme with no opinion of its own" do
      assert BookingText.default_heading(:some_future_theme, "Sam") ==
               BookingText.default_heading(:quill, "Sam")
    end
  end

  defp customized(attrs) do
    build(:profile, Keyword.put(attrs, :booking_text_enabled, true))
  end
end
