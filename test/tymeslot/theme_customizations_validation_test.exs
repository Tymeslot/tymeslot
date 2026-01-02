defmodule Tymeslot.ThemeCustomizationsValidationTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.ThemeCustomizations.{Presets, Validation}

  describe "Validation module" do
    test "validate_color_scheme/1 validates known schemes" do
      assert Validation.validate_color_scheme("purple") == :ok
      assert Validation.validate_color_scheme("ocean") == :ok
    end

    test "validate_color_scheme/1 rejects unknown schemes" do
      assert {:error, _} = Validation.validate_color_scheme("unknown_scheme")
    end

    test "validate_color_scheme/2 validates against custom map" do
      custom = %{"my_scheme" => %{name: "Custom"}}

      assert Validation.validate_color_scheme("my_scheme", custom) == :ok
      assert {:error, _} = Validation.validate_color_scheme("unknown", custom)
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
      assert {:error, _} = Validation.validate_background_value("gradient", "unknown", presets)
    end

    test "validate_background_value/3 validates colors" do
      assert Validation.validate_background_value("color", "#ff5500", %{}) == :ok
      assert {:error, _} = Validation.validate_background_value("color", "invalid", %{})
    end

    test "validate_background_value/3 validates images" do
      presets = %{images: %{"preset:test" => %{}}}

      assert Validation.validate_background_value("image", "custom", presets) == :ok
      assert Validation.validate_background_value("image", "preset:test", presets) == :ok
      assert {:error, _} = Validation.validate_background_value("image", "unknown", presets)
    end

    test "validate_background_value/3 validates videos" do
      presets = %{videos: %{"preset:test" => %{}}}

      assert Validation.validate_background_value("video", "custom", presets) == :ok
      assert Validation.validate_background_value("video", "preset:test", presets) == :ok
      assert {:error, _} = Validation.validate_background_value("video", "unknown", presets)
    end

    test "validate_background_selection/3 validates complete selection" do
      presets = Presets.get_all_presets()

      assert Validation.validate_background_selection("gradient", "gradient_1", presets) == :ok
      assert {:error, _} = Validation.validate_background_selection("invalid", "value", presets)
    end

    test "validate_hex_color/1 accepts valid hex colors" do
      assert Validation.validate_hex_color("#ff5500") == :ok
      assert Validation.validate_hex_color("#AABBCC") == :ok
      assert Validation.validate_hex_color("#000000") == :ok
    end

    test "validate_hex_color/1 rejects invalid hex colors" do
      assert {:error, _} = Validation.validate_hex_color("ff5500")
      assert {:error, _} = Validation.validate_hex_color("#ff550")
      assert {:error, _} = Validation.validate_hex_color("#gggggg")
      assert {:error, _} = Validation.validate_hex_color(123)
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
      assert {:error, _} = Validation.sanitize_customization_input("not a map")
    end

    test "validate_file_extension/2 validates image extensions" do
      assert Validation.validate_file_extension("image.jpg", :image) == :ok
      assert Validation.validate_file_extension("image.png", :image) == :ok
      assert Validation.validate_file_extension("image.webp", :image) == :ok
      assert {:error, _} = Validation.validate_file_extension("image.exe", :image)
    end

    test "validate_file_extension/2 validates video extensions" do
      assert Validation.validate_file_extension("video.mp4", :video) == :ok
      assert Validation.validate_file_extension("video.webm", :video) == :ok
      assert {:error, _} = Validation.validate_file_extension("video.exe", :video)
    end

    test "validate_file_extension/2 handles unknown types" do
      assert {:error, _} = Validation.validate_file_extension("file.txt", :unknown)
    end
  end
end
