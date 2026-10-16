defmodule Tymeslot.Profiles.IntroInputValidationTest do
  use Tymeslot.DataCase, async: true

  @moduledoc """
  The headline and bio go through the plain-text sanitiser before the changeset
  sees them, like the booking text: real prose keeps its punctuation and the
  bio its line breaks, while malformed bytes and non-text values are refused.
  """
  @moduletag :profiles
  @moduletag :unit

  alias Tymeslot.Profiles.InputValidation

  describe "validate_intro/2" do
    test "keeps punctuation and the bio's line breaks" do
      params = %{
        "headline" => "Coach -- mentor <for new managers>",
        "bio" => "Hi, I'm \"Sam\".\n\nLet's talk."
      }

      assert {:ok, out} = InputValidation.validate_intro(params)
      assert out["headline"] == "Coach -- mentor <for new managers>"
      assert out["bio"] == "Hi, I'm \"Sam\".\n\nLet's talk."
    end

    test "strips null bytes" do
      assert {:ok, %{"bio" => bio}} = InputValidation.validate_intro(%{"bio" => "Hi\x00 there"})
      refute bio =~ "\x00"
    end

    test "refuses malformed encoding" do
      assert {:error, %{bio: _message}} =
               InputValidation.validate_intro(%{"bio" => <<0xFF, 0xFE, "broken">>})
    end

    test "refuses a value that is not text" do
      assert {:error, %{headline: _message}} = InputValidation.validate_intro(%{"headline" => 42})
    end

    test "passes through params it does not own, and fields not submitted" do
      params = %{"other" => "untouched"}

      assert {:ok, ^params} = InputValidation.validate_intro(params)
    end
  end
end
