defmodule Tymeslot.ThemeCustomizationsValidationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.Validation

  describe "Validation module" do
    # Defence-in-depth sanitiser for values that end up injected into a
    # stylesheet. Each payload is a real-world break-out vector.
    test "sanitize_css/1 passes benign CSS through unchanged" do
      css = "--theme-background: #ff5500;\n--theme-foreground: #000;"
      assert Validation.sanitize_css(css) == css
    end

    test "sanitize_css/1 blanks out </style> break-out attempts" do
      assert Validation.sanitize_css("--x: red;</style><script>alert(1)</script>") == ""
      assert Validation.sanitize_css("--x: red;</STYLE>") == ""
      assert Validation.sanitize_css("--x: red;< / style >") == ""
    end

    test "sanitize_css/1 blanks out @import payloads" do
      assert Validation.sanitize_css("@import url('https://evil.example/steal.css');") == ""
      assert Validation.sanitize_css("--x: red;@IMPORT 'evil.css';") == ""
    end

    test "sanitize_css/1 blanks out legacy IE expression() payloads" do
      assert Validation.sanitize_css("--x: expression(alert(1));") == ""
      assert Validation.sanitize_css("--x: Expression (alert(1));") == ""
    end

    test "sanitize_css/1 blanks out javascript: URLs" do
      assert Validation.sanitize_css("--theme-background-image: url('javascript:alert(1)');") ==
               ""

      assert Validation.sanitize_css("content: JAVASCRIPT:alert(1);") == ""
    end

    test "sanitize_css/1 blanks out data:text/html payloads" do
      assert Validation.sanitize_css("--x: url(data:text/html,<script>1</script>);") == ""
      assert Validation.sanitize_css("--x: url( \"data:text/html;base64,PHNjcmlwdD4=\" );") == ""
    end

    test "sanitize_css/1 blanks out data:application/javascript payloads" do
      assert Validation.sanitize_css("--x: url(data:application/javascript,alert(1));") == ""
    end

    test "sanitize_css/1 blanks out data:application/xhtml+xml payloads" do
      assert Validation.sanitize_css(
               "--x: url(data:application/xhtml+xml,<script>alert(1)</script>);"
             ) == ""
    end

    test "sanitize_css/1 returns empty string for non-binary input" do
      assert Validation.sanitize_css(nil) == ""
      assert Validation.sanitize_css(123) == ""
    end
  end
end
