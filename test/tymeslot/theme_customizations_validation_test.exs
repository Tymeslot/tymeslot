defmodule Tymeslot.ThemeCustomizationsValidationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.{Presets, Validation}

  describe "Validation module" do
    test "validate_color_scheme/1 validates known schemes" do
      assert Validation.validate_color_scheme("purple") == :ok
      assert Validation.validate_color_scheme("ocean") == :ok
    end

    test "validate_color_scheme/1 rejects unknown schemes" do
      assert {:error, _reason} = Validation.validate_color_scheme("unknown_scheme")
    end

    test "validate_color_scheme/2 validates against custom map" do
      custom = %{"my_scheme" => %{name: "Custom"}}

      assert Validation.validate_color_scheme("my_scheme", custom) == :ok
      assert {:error, _reason} = Validation.validate_color_scheme("unknown", custom)
    end

    test "validate_background_type/1 accepts valid types" do
      assert Validation.validate_background_type("gradient") == :ok
      assert Validation.validate_background_type("color") == :ok
      assert Validation.validate_background_type("image") == :ok
      assert Validation.validate_background_type("video") == :ok
    end

    test "validate_background_type/1 rejects invalid types" do
      assert {:error, msg} = Validation.validate_background_type("unknown")
      assert msg =~ "Invalid background type"
    end

    test "validate_background_value/3 validates gradients" do
      presets = %{gradients: %{"gradient_1" => %{}}}

      assert Validation.validate_background_value("gradient", "gradient_1", presets) == :ok

      assert {:error, _reason} =
               Validation.validate_background_value("gradient", "unknown", presets)
    end

    test "validate_background_value/3 validates colors" do
      assert Validation.validate_background_value("color", "#ff5500", %{}) == :ok
      assert {:error, _reason} = Validation.validate_background_value("color", "invalid", %{})
    end

    test "validate_background_value/3 validates images" do
      presets = %{images: %{"preset:test" => %{}}}

      assert Validation.validate_background_value("image", "custom", presets) == :ok
      assert Validation.validate_background_value("image", "preset:test", presets) == :ok
      assert {:error, _reason} = Validation.validate_background_value("image", "unknown", presets)
    end

    test "validate_background_value/3 validates videos" do
      presets = %{videos: %{"preset:test" => %{}}}

      assert Validation.validate_background_value("video", "custom", presets) == :ok
      assert Validation.validate_background_value("video", "preset:test", presets) == :ok
      assert {:error, _reason} = Validation.validate_background_value("video", "unknown", presets)
    end

    test "validate_background_selection/3 validates complete selection" do
      presets = Presets.get_all_presets()

      assert Validation.validate_background_selection("gradient", "gradient_1", presets) == :ok

      assert {:error, _reason} =
               Validation.validate_background_selection("invalid", "value", presets)
    end

    test "validate_hex_color/1 accepts valid hex colors" do
      assert Validation.validate_hex_color("#ff5500") == :ok
      assert Validation.validate_hex_color("#AABBCC") == :ok
      assert Validation.validate_hex_color("#000000") == :ok
    end

    test "validate_hex_color/1 accepts short #RGB form" do
      assert Validation.validate_hex_color("#fff") == :ok
      assert Validation.validate_hex_color("#ABC") == :ok
    end

    test "validate_hex_color/1 accepts #RRGGBBAA alpha form" do
      assert Validation.validate_hex_color("#FFFFFFFF") == :ok
      assert Validation.validate_hex_color("#0011aa33") == :ok
    end

    test "validate_hex_color/1 accepts uppercase hex digits" do
      assert Validation.validate_hex_color("#ABCDEF") == :ok
    end

    test "validate_hex_color/1 ignores surrounding whitespace" do
      assert Validation.validate_hex_color("  #ff5500  ") == :ok
      assert Validation.validate_hex_color("\t#fff\n") == :ok
    end

    test "validate_hex_color/1 rejects invalid hex colors" do
      assert {:error, _reason} = Validation.validate_hex_color("ff5500")
      assert {:error, _reason} = Validation.validate_hex_color("#ff550")
      assert {:error, _reason} = Validation.validate_hex_color("#gggggg")
      assert {:error, _reason} = Validation.validate_hex_color(123)
      # seven digits — not a valid CSS hex length
      assert {:error, _reason} = Validation.validate_hex_color("#1234567")
    end

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

    test "validate_customization_changes/1 validates multiple fields" do
      changes = %{color_scheme: "purple", background_type: "gradient"}

      assert Validation.validate_customization_changes(changes) == :ok
    end

    test "validate_customization_changes/1 collects errors" do
      changes = %{color_scheme: "invalid_scheme", background_type: "invalid_type"}

      assert {:error, errors} = Validation.validate_customization_changes(changes)
      assert length(errors) == 2
    end

    test "sanitize_customization_input/1 trims string values" do
      attrs = %{"color_scheme" => "  purple  ", "background_type" => " gradient "}

      {:ok, sanitized} = Validation.sanitize_customization_input(attrs)

      assert sanitized["color_scheme"] == "purple"
      assert sanitized["background_type"] == "gradient"
    end

    test "sanitize_customization_input/1 rejects non-map input" do
      assert {:error, _reason} = Validation.sanitize_customization_input("not a map")
    end

    test "validate_file_extension/2 validates image extensions" do
      assert Validation.validate_file_extension("image.jpg", :image) == :ok
      assert Validation.validate_file_extension("image.png", :image) == :ok
      assert Validation.validate_file_extension("image.webp", :image) == :ok
      assert {:error, _reason} = Validation.validate_file_extension("image.exe", :image)
    end

    test "validate_file_extension/2 validates video extensions" do
      assert Validation.validate_file_extension("video.mp4", :video) == :ok
      assert Validation.validate_file_extension("video.webm", :video) == :ok
      assert {:error, _reason} = Validation.validate_file_extension("video.exe", :video)
    end

    test "validate_file_extension/2 handles unknown types" do
      assert {:error, _reason} = Validation.validate_file_extension("file.txt", :unknown)
    end
  end
end
