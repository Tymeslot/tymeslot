defmodule Tymeslot.Emails.Shared.AvatarHelperTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.AvatarHelper
  alias Tymeslot.Emails.Shared.Styles
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Utils.Colour

  describe "avatar_mjml/2 with an absolute avatar URL" do
    test "renders the uploaded image" do
      mjml = AvatarHelper.avatar_mjml("https://example.com/uploads/avatars/1/me.png", "Jane Doe")

      assert mjml =~ ~s(<mj-image)
      assert mjml =~ ~s(src="https://example.com/uploads/avatars/1/me.png")
      assert mjml =~ ~s(alt="Jane Doe")
    end
  end

  describe "avatar_mjml/2 without a usable avatar URL" do
    for {label, url} <- [
          {"nil", nil},
          {"a site-relative path", "/uploads/avatars/1/me.png"},
          {"a data URI", "data:image/svg+xml;base64,PHN2Zz4="},
          {"a javascript URL", "javascript:alert(1)"}
        ] do
      test "renders an initials badge and no image for #{label}" do
        mjml = AvatarHelper.avatar_mjml(unquote(url), "Jane Doe")

        refute mjml =~ "<mj-image"
        refute mjml =~ "data:"
        assert mjml =~ ~r{>JD</td>}
      end
    end

    test "draws the initials in a colour that clears 4.5:1 against the deep accent circle" do
      mjml = AvatarHelper.avatar_mjml(nil, "Jane Doe")

      accent_deep = Tokens.intent_accent_deep(:confirmed)
      expected_text = Styles.button_text_color(accent_deep)

      assert mjml =~ "background-color:#{accent_deep};color:#{expected_text};"
      assert expected_text == Styles.surface()
      assert Colour.contrast_ratio(expected_text, accent_deep) >= 4.5
    end

    test "escapes the initials" do
      assert AvatarHelper.avatar_mjml(nil, "<b>") =~ ~r{>&lt;</td>}
    end
  end

  describe "initials/1" do
    test "takes the first and last words so long names fit the badge" do
      assert AvatarHelper.initials("maria del carmen lopez") == "ML"
    end

    test "uses a single initial for a one-word name" do
      assert AvatarHelper.initials("Jane") == "J"
    end

    test "falls back to a placeholder for a blank or missing name" do
      assert AvatarHelper.initials("  ") == "U"
      assert AvatarHelper.initials(nil) == "U"
    end
  end
end
