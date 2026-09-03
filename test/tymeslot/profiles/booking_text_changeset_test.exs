defmodule Tymeslot.Profiles.BookingTextChangesetTest do
  use Tymeslot.DataCase, async: true

  @moduledoc """
  The booking page's introductory text is what a visitor reads first, so the
  changeset has to refuse to put a half-filled version of it on a public page,
  while still letting an organiser switch the customisation off without losing
  the wording they wrote.
  """
  @moduletag :themes
  @moduletag :schema

  import Tymeslot.Factory

  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Validation.Constraints

  describe "when the customisation is switched on" do
    test "accepts a complete set of wording" do
      changeset = change_text(Map.merge(complete_text(), %{booking_text_enabled: true}))

      assert changeset.valid?
      assert get_change(changeset, :booking_heading) == "Let's build something"
    end

    test "refuses to publish with any of the three lines blank" do
      for field <- [:booking_heading, :booking_greeting, :booking_instruction] do
        attrs =
          complete_text()
          |> Map.put(:booking_text_enabled, true)
          |> Map.put(field, "")

        changeset = change_text(attrs)

        refute changeset.valid?,
               "expected a blank #{field} to be refused while the text is live"

        assert errors_on(changeset)[field] == ["can't be blank"]
      end
    end

    test "treats whitespace-only wording as blank" do
      changeset =
        complete_text()
        |> Map.put(:booking_text_enabled, true)
        |> Map.put(:booking_heading, "   \t  ")
        |> change_text()

      refute changeset.valid?
      assert %{booking_heading: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "when the customisation is switched off" do
    test "keeps the stored wording rather than clearing it" do
      profile =
        build(:profile,
          booking_text_enabled: true,
          booking_heading: "Let's build something",
          booking_greeting: "Hi! I'm Sam.",
          booking_instruction: "Pick a slot."
        )

      changeset = ProfileSchema.booking_text_changeset(profile, %{booking_text_enabled: false})

      assert changeset.valid?
      assert get_field(changeset, :booking_heading) == "Let's build something"
      assert get_field(changeset, :booking_greeting) == "Hi! I'm Sam."
    end

    test "accepts blank wording, because nothing is on the page" do
      changeset =
        change_text(%{
          booking_text_enabled: false,
          booking_heading: "",
          booking_greeting: "",
          booking_instruction: ""
        })

      assert changeset.valid?
    end
  end

  describe "sanitisation" do
    test "trims surrounding whitespace" do
      changeset =
        complete_text()
        |> Map.put(:booking_text_enabled, true)
        |> Map.put(:booking_heading, "  Let's talk  ")
        |> change_text()

      assert get_change(changeset, :booking_heading) == "Let's talk"
    end

    test "strips null bytes, which Postgres rejects despite them being valid UTF-8" do
      changeset =
        complete_text()
        |> Map.put(:booking_text_enabled, true)
        |> Map.put(:booking_greeting, "Hi!\x00 I'm Sam.")
        |> change_text()

      assert changeset.valid?
      refute get_change(changeset, :booking_greeting) =~ "\x00"
      assert get_change(changeset, :booking_greeting) == "Hi! I'm Sam."
    end

    test "clearing a field that already had wording actually clears it" do
      profile = build(:profile, booking_heading: "Old heading")

      changeset =
        ProfileSchema.booking_text_changeset(profile, %{
          booking_text_enabled: false,
          booking_heading: ""
        })

      assert get_field(changeset, :booking_heading) == nil
    end
  end

  describe "length" do
    test "refuses a heading past the cap that keeps the page usable on a short screen" do
      max = Constraints.booking_heading_max_length()

      changeset =
        complete_text()
        |> Map.put(:booking_text_enabled, true)
        |> Map.put(:booking_heading, String.duplicate("a", max + 1))
        |> change_text()

      refute changeset.valid?
      assert %{booking_heading: [message]} = errors_on(changeset)
      assert message =~ "should be at most"
    end

    test "accepts a heading exactly at the cap" do
      max = Constraints.booking_heading_max_length()

      changeset =
        complete_text()
        |> Map.put(:booking_text_enabled, true)
        |> Map.put(:booking_heading, String.duplicate("a", max))
        |> change_text()

      assert changeset.valid?
    end

    test "refuses a welcome line past its own, looser cap" do
      max = Constraints.booking_welcome_line_max_length()

      changeset =
        complete_text()
        |> Map.put(:booking_text_enabled, true)
        |> Map.put(:booking_instruction, String.duplicate("a", max + 1))
        |> change_text()

      refute changeset.valid?
      assert %{booking_instruction: [_message]} = errors_on(changeset)
    end
  end

  defp complete_text do
    %{
      booking_heading: "Let's build something",
      booking_greeting: "Hi! I'm Sam.",
      booking_instruction: "Pick a slot."
    }
  end

  defp change_text(attrs), do: ProfileSchema.booking_text_changeset(build(:profile), attrs)
end
