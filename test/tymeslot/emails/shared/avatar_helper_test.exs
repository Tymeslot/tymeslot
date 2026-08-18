defmodule Tymeslot.Emails.Shared.AvatarHelperTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.AvatarHelper
  alias Tymeslot.Emails.Shared.Styles
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Utils.Colour

  describe "generate_default_avatar/1" do
    test "draws the initials in a colour that clears 4.5:1 against the deep accent circle" do
      svg =
        "Jane Doe"
        |> AvatarHelper.generate_default_avatar()
        |> String.trim_leading("data:image/svg+xml;base64,")
        |> Base.decode64!()

      accent_deep = Tokens.intent_accent_deep(:confirmed)
      expected_text = Styles.button_text_color(accent_deep)

      assert svg =~ ~s(fill="#{accent_deep}")
      assert svg =~ ~s(fill="#{expected_text}")
      assert Colour.contrast_ratio(expected_text, accent_deep) >= 4.5
    end

    test "the stock avatar circle resolves to light text, not dark ink" do
      svg =
        "Jane Doe"
        |> AvatarHelper.generate_default_avatar()
        |> String.trim_leading("data:image/svg+xml;base64,")
        |> Base.decode64!()

      assert svg =~ ~s(fill="#{Tokens.intent_accent_deep(:confirmed)}")
      assert svg =~ ~s(fill="#{Styles.surface()}")
    end

    test "still renders the initials" do
      svg =
        "Jane Doe"
        |> AvatarHelper.generate_default_avatar()
        |> String.trim_leading("data:image/svg+xml;base64,")
        |> Base.decode64!()

      assert svg =~ "JD"
    end
  end
end
