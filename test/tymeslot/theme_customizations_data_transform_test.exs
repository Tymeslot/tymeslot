defmodule Tymeslot.ThemeCustomizationsDataTransformTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.DataTransform
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  describe "to_settings/1" do
    test "takes the stored settings of a customisation, string-keyed" do
      customization = %ThemeCustomizationSchema{
        id: 3,
        profile_id: 1,
        theme_id: "1",
        settings: %{
          "color_scheme" => "purple",
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => "themes/1/1/images/a.jpg"
        },
        video_processing_status: %{"background_video_path" => "pending"}
      }

      assert DataTransform.to_settings(customization) == %{
               "color_scheme" => "purple",
               "background_type" => "image",
               "background_value" => "custom",
               "background_image_path" => "themes/1/1/images/a.jpg"
             }
    end

    test "normalises an atom-keyed map of settings, string-keyed" do
      assert DataTransform.to_settings(%{color_scheme: "purple", background_type: "gradient"}) ==
               %{"color_scheme" => "purple", "background_type" => "gradient"}
    end

    test "is empty for nil" do
      assert DataTransform.to_settings(nil) == %{}
    end
  end
end
