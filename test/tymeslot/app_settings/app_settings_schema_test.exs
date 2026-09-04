defmodule Tymeslot.AppSettings.AppSettingsSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Ecto.Changeset
  alias Tymeslot.AppSettings.AppSettingsSchema
  alias Tymeslot.Locales

  describe "changeset/2 locale default validation" do
    test "accepts a supported locale code for each surface" do
      changeset =
        AppSettingsSchema.changeset(%AppSettingsSchema{}, %{
          admin_default_locale: "de",
          booking_default_locale: "fr"
        })

      assert changeset.valid?
      assert Changeset.get_change(changeset, :admin_default_locale) == "de"
      assert Changeset.get_change(changeset, :booking_default_locale) == "fr"
    end

    test "rejects a locale code this install does not support" do
      changeset =
        AppSettingsSchema.changeset(%AppSettingsSchema{}, %{admin_default_locale: "zz"})

      refute changeset.valid?
      assert "is not a supported language" in errors_on(changeset).admin_default_locale
    end

    test "rejects a well-formed code that is simply not in the supported set" do
      # "es" is a real locale and would pass any format check; only the
      # configured set can reject it.
      refute "es" in Locales.supported_codes()

      changeset =
        AppSettingsSchema.changeset(%AppSettingsSchema{}, %{booking_default_locale: "es"})

      refute changeset.valid?
    end

    test "accepts nil, which clears the override" do
      changeset =
        AppSettingsSchema.changeset(
          %AppSettingsSchema{admin_default_locale: "de"},
          %{admin_default_locale: nil}
        )

      assert changeset.valid?
      assert Changeset.get_change(changeset, :admin_default_locale) == nil
    end

    test "a blank submission clears the override rather than storing an empty string" do
      changeset =
        AppSettingsSchema.changeset(
          %AppSettingsSchema{booking_default_locale: "fr"},
          %{booking_default_locale: "  "}
        )

      assert changeset.valid?
      assert Changeset.get_change(changeset, :booking_default_locale) == nil
    end
  end

  describe "changeset/2 email_brand_name validation" do
    test "rejects a name over the 60-grapheme display cap" do
      changeset =
        AppSettingsSchema.changeset(%AppSettingsSchema{}, %{
          email_brand_name: String.duplicate("a", 61)
        })

      refute changeset.valid?
      assert "should be at most 60 character(s)" in errors_on(changeset).email_brand_name
    end

    test "rejects a multi-byte name within the grapheme cap but over the 255-byte column limit" do
      # 40 grapheme clusters (under the 60-grapheme cap), each a 7-codepoint,
      # 25-byte ZWJ family emoji: 280 codepoints and 1000 bytes total — both
      # over what the varchar(255) column can hold, which validate_length's
      # default :graphemes count misses entirely.
      family_emoji = "👨‍👩‍👧‍👦"
      name = String.duplicate(family_emoji, 40)

      assert String.length(name) <= 60
      assert byte_size(name) > 255

      changeset =
        AppSettingsSchema.changeset(%AppSettingsSchema{}, %{email_brand_name: name})

      refute changeset.valid?
      assert "should be at most 255 byte(s)" in errors_on(changeset).email_brand_name
    end

    test "accepts a name within both the grapheme and byte caps" do
      changeset =
        AppSettingsSchema.changeset(%AppSettingsSchema{}, %{email_brand_name: "Beaver Dental"})

      assert changeset.valid?
    end
  end
end
