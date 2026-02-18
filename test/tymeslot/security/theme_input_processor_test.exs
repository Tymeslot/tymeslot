defmodule Tymeslot.Security.ThemeInputProcessorTest do
  @moduletag :security
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.ThemeInputProcessor
  alias Tymeslot.Themes.Theme

  describe "validate_theme_selection/2" do
  @moduletag :security
    test "accepts valid theme selection" do
      # Get a valid theme ID from the registry
      case Theme.theme_options() do
        [{_name, id} | _rest] ->
          assert {:ok, %{"theme" => ^id}} =
                   ThemeInputProcessor.validate_theme_selection(%{"theme" => id})

        [] ->
          # If no themes are registered, this test might need adjustment
          :ok
      end
    end

    test "rejects missing theme" do
      assert {:error, errors} = ThemeInputProcessor.validate_theme_selection(%{})
      assert errors[:theme] == ["Theme selection is required"]
    end

    test "rejects invalid theme id" do
      assert {:error, errors} =
               ThemeInputProcessor.validate_theme_selection(%{"theme" => "non-existent-theme"})

      assert errors[:theme] == ["Invalid theme selection"]
    end

    test "rejects non-string theme id" do
      assert {:error, errors} = ThemeInputProcessor.validate_theme_selection(%{"theme" => 123})
      assert errors[:theme] == ["Theme selection must be a string"]
    end

    test "rejects input with sanitization changes" do
      assert {:error, errors} =
               ThemeInputProcessor.validate_theme_selection(%{"theme" => "1<script>"})

      assert errors[:theme] == ["Invalid characters in theme selection"]
    end
  end
end
