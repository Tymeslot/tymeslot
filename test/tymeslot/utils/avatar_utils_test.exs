defmodule Tymeslot.Utils.AvatarUtilsTest do
  use ExUnit.Case, async: true

  @moduletag :profiles

  alias Tymeslot.Utils.AvatarUtils
  alias Tymeslot.Utils.Colour

  test "every gradient's initials reach 3:1 against both of its stops" do
    for %{start: start, end: stop, ink: ink} <- AvatarUtils.gradients(),
        stop_colour <- [start, stop] do
      ratio = Colour.contrast_ratio(ink, stop_colour)

      assert ratio >= 3.0,
             "#{ink} on #{start} to #{stop} reaches only #{Float.round(ratio, 2)}:1 against #{stop_colour}"
    end
  end

  test "a gradient white already reads on keeps white initials" do
    assert %{ink: "#ffffff"} =
             Enum.find(AvatarUtils.gradients(), &(&1.start == "#667eea"))
  end

  test "the drawn avatar uses its gradient's ink" do
    svg =
      %{id: 42, full_name: "Ada Lovelace", user: nil}
      |> AvatarUtils.generate_fallback_data_uri(64)
      |> String.replace_prefix("data:image/svg+xml;base64,", "")
      |> Base.decode64!()

    [start] = Regex.run(~r/stop-color:(#[0-9a-f]{6})/, svg, capture: :all_but_first)
    %{ink: ink} = Enum.find(AvatarUtils.gradients(), &(&1.start == start))

    assert svg =~ ~s(fill="#{ink}">AL</text>)
  end

  describe "initials/1" do
    test "takes the first letters of the first two words of the full name" do
      assert AvatarUtils.initials(%{full_name: "  ada byron lovelace ", user: nil}) == "AB"
    end

    test "falls back to the email's first letter, then to U" do
      assert AvatarUtils.initials(%{full_name: " ", user: %{email: "grace@example.com"}}) == "G"
      assert AvatarUtils.initials(%{full_name: nil, user: nil}) == "U"
      assert AvatarUtils.initials(nil) == "U"
    end
  end
end
