defmodule TymeslotWeb.Gettext.PseudoTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Gettext.Pseudo

  describe "transform/1" do
    test "wraps translated prose in the ⟦…⟧ coverage markers" do
      result = Pseudo.transform("Save changes")

      assert String.starts_with?(result, "⟦")
      assert String.ends_with?(result, "⟧")
    end

    test "accents Latin letters so the text reads as foreign" do
      result = Pseudo.transform("Save")

      # Every ASCII letter is replaced by an accented look-alike.
      refute result =~ ~r/[A-Za-z]/
      assert result =~ "Š"
    end

    test "pads the string to expose truncation and overflow" do
      # The padded pseudo form is longer than the original source string.
      assert String.length(Pseudo.transform("Save")) > String.length("Save")
      assert Pseudo.transform("Save") =~ "·"
    end

    test "leaves interpolation values in place (transform runs post-interpolation)" do
      # The backend interpolates first, so bindings arrive as plain text and are
      # simply accented along with everything else — never dropped.
      result = Pseudo.transform("Hi Alice")

      assert result =~ "⟦"
      assert result =~ "Ħí"
    end

    test "returns strings without Latin letters unchanged" do
      assert Pseudo.transform("→") == "→"
      assert Pseudo.transform("") == ""
      assert Pseudo.transform("123 · !") == "123 · !"
    end
  end
end
