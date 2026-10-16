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
  alias Tymeslot.Themes.Catalog
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
  end

  describe "defaults" do
    test "follow each theme's catalogue heading style" do
      themes = Catalog.all()
      assert map_size(themes) > 0

      for {key, facts} <- themes do
        heading = BookingText.default_heading(key, "Sam")

        case facts.heading_style do
          :named -> assert heading =~ "Sam"
          :generic -> refute heading =~ "Sam"
        end
      end
    end

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

    test "fall back to the generic heading when there is no name to put in it" do
      assert BookingText.default_heading(:rhythm, nil) == BookingText.default_heading(:quill, nil)
      refute BookingText.default_heading(:rhythm, nil) =~ "Schedule with"
    end
  end

  describe "duration_label/1" do
    test "reads the meeting type's own duration first" do
      assigns = %{
        meeting_type: build(:meeting_type, duration_minutes: 45),
        duration: "30-minutes"
      }

      assert BookingText.duration_label(assigns) == "45 minutes"
    end

    test "falls back to the selected duration when there is no meeting type" do
      assert BookingText.duration_label(%{meeting_type: nil, duration: "30-minutes"}) ==
               "30 minutes"

      assert BookingText.duration_label(%{meeting_type: nil, duration: "90min"}) ==
               "1 hour 30 minutes"
    end

    test "says so when neither gives a duration it can read" do
      assert BookingText.duration_label(%{meeting_type: nil, duration: "intro-call"}) ==
               "Unknown duration"

      assert BookingText.duration_label(%{}) == "Unknown duration"
    end

    test "translates the fallback as well as the meeting type's duration" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      assert BookingText.duration_label(%{meeting_type: nil, duration: "30-minutes"}) ==
               "30 Minuten"
    end
  end

  describe "price_label/3" do
    test "formats a paid type's price in the organiser's currency" do
      paid = build(:meeting_type, payment_required: true, price_cents: 4500)

      assert BookingText.price_label(paid, "chf", "en") == "CHF 45.00"
      assert BookingText.price_label(paid, "eur", "en") == "€45.00"
    end

    test "writes the price the way the guest's locale writes amounts" do
      paid = build(:meeting_type, payment_required: true, price_cents: 4500)

      assert BookingText.price_label(paid, "eur", "de") == "45,00\u00A0€"
    end

    test "is nil for a free type, a paid type without a price, or an unknown currency" do
      assert BookingText.price_label(
               build(:meeting_type, payment_required: false, price_cents: 4500),
               "eur",
               "en"
             ) == nil

      assert BookingText.price_label(
               build(:meeting_type, payment_required: true, price_cents: nil),
               "eur",
               "en"
             ) == nil

      assert BookingText.price_label(
               build(:meeting_type, payment_required: true, price_cents: 4500),
               nil,
               "en"
             ) == nil

      assert BookingText.price_label(nil, "eur", "en") == nil
      # A demo persona's meeting type is a plain map without the fields.
      assert BookingText.price_label(%{name: "Coffee Chat"}, "eur", "en") == nil
    end
  end

  describe "a theme's voice" do
    # The fixture theme's voice words the heading, greeting and instruction;
    # the showcase theme has no voice. Both are test-only themes with the
    # :generic heading style.
    test "words the default heading of the theme that has it" do
      assert BookingText.default_heading(:fixture, "Sam") == "Book a time"
      assert BookingText.default_heading(:showcase, "Sam") == "Let's Connect!"
    end

    test "reaches the page's heading only while the organiser has no wording of their own" do
      assert BookingText.heading(build(:profile), :fixture, "Sam") == "Book a time"

      assert BookingText.heading(customized(booking_heading: "Mine"), :fixture, "Sam") ==
               "Mine"
    end

    test "words the default greeting and instruction of the theme that has it" do
      assert BookingText.default_greeting("Sam", :fixture) == "Hello, Sam here."
      assert BookingText.default_instruction(:fixture) == "Choose a meeting to start."
      assert BookingText.default_greeting("Sam", :showcase) == "Hi! I'm Sam."
      assert BookingText.default_instruction(:showcase) == "Pick an option below."
    end

    test "reaches the greeting and instruction only while the organiser has no wording of their own" do
      assert BookingText.greeting(build(:profile), "Sam", :fixture) == "Hello, Sam here."
      assert BookingText.instruction(build(:profile), :fixture) == "Choose a meeting to start."

      own = customized(booking_greeting: "Hey", booking_instruction: "Pick one")
      assert BookingText.greeting(own, "Sam", :fixture) == "Hey"
      assert BookingText.instruction(own, :fixture) == "Pick one"
    end

    test "still drops the greeting when there is no name to introduce" do
      assert BookingText.default_greeting(nil, :fixture) == nil
    end
  end

  defp customized(attrs) do
    build(:profile, Keyword.put(attrs, :booking_text_enabled, true))
  end
end
