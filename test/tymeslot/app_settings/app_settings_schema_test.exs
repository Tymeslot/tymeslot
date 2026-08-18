defmodule Tymeslot.AppSettings.AppSettingsSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.AppSettings.AppSettingsSchema

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
