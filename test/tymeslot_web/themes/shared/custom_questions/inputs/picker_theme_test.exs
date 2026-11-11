defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.PickerThemeTest do
  @moduledoc """
  The date and time pickers on a booking page read the theme's own tokens, so
  every shipped theme's stylesheet must bring their rules in; a theme that left
  the import out would show a bare, unstyled panel.
  """
  use ExUnit.Case, async: true

  @moduletag :themes

  alias TymeslotWeb.ThemeTestMatrix

  test "every shipped theme imports the picker's themed rules" do
    themes = ThemeTestMatrix.all()
    assert themes != []

    missing =
      Enum.reject(themes, fn theme ->
        ["assets/css/scheduling/themes", theme.slug, "theme.css"]
        |> Path.join()
        |> File.read!()
        |> String.contains?(~s(@import "../../shared/components/date-time-picker.css";))
      end)

    assert missing == []
  end
end
