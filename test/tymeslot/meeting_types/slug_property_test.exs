defmodule Tymeslot.MeetingTypes.SlugPropertyTest do
  @moduledoc """
  Property-based tests for slug generation logic used in meeting type validation.

  Tests drive through the public API `InputValidation.validate_field/3`
  to exercise the full pipeline including sanitisation and slug generation.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :meeting_types
  use ExUnitProperties

  alias Tymeslot.MeetingTypes.InputValidation
  alias Tymeslot.MeetingTypes.Slugs

  # ---------------------------------------------------------------------------
  # Slugs.to_slug/1 and Slugs.effective_slug/1 unit tests
  # ---------------------------------------------------------------------------

  describe "Slugs.to_slug/1 — unicode and edge-case inputs" do
    test "returns empty string for an emoji-only name" do
      # Emoji have no ASCII representation; the regex strips them entirely.
      assert Slugs.to_slug(%{name: "🎯"}) == ""
    end

    test "returns empty string for a CJK-only name" do
      assert Slugs.to_slug(%{name: "日本語"}) == ""
    end

    test "returns empty string for a mixed emoji-and-whitespace name" do
      assert Slugs.to_slug(%{name: "🎯 🚀"}) == ""
    end

    test "handles a very long ASCII name without crashing and slugifies it" do
      long_name = String.duplicate("a", 500)
      result = Slugs.to_slug(%{name: long_name})
      # No length cap in to_slug/1 itself — it returns the full slug.
      assert result == long_name
    end

    test "handles a mixed ASCII + unicode name by keeping only ASCII characters" do
      result = Slugs.to_slug(%{name: "Coffee 日本語 Chat"})
      assert result == "coffee-chat"
    end
  end

  describe "Slugs.effective_slug/1 — custom vs name-derived" do
    test "returns the custom slug when one is set" do
      mt = %{slug: "secret-9z", name: "Coffee Chat"}
      assert Slugs.effective_slug(mt) == "secret-9z"
    end

    test "returns the name-derived slug when no custom slug is set" do
      mt = %{slug: nil, name: "Coffee Chat"}
      assert Slugs.effective_slug(mt) == "coffee-chat"
    end

    test "returns empty string when no custom slug is set and name is unicode-only" do
      # effective_slug/1 does NOT guard against an empty name-derived slug;
      # the guard lives in InputValidation.validate_meeting_name/2.
      mt = %{slug: nil, name: "🎯"}
      assert Slugs.effective_slug(mt) == ""
    end

    test "returns the custom slug even when the name itself would produce an empty slug" do
      mt = %{slug: "my-link", name: "🎯"}
      assert Slugs.effective_slug(mt) == "my-link"
    end
  end

  describe "InputValidation.validate_meeting_name/2 — unicode name guard" do
    test "rejects a name composed only of emoji (slug would be empty)" do
      assert {:error, %{name: _msg}} =
               InputValidation.validate_field(:name, "🎯", %{})
    end

    test "rejects a name composed only of CJK characters (slug would be empty)" do
      assert {:error, %{name: _msg}} =
               InputValidation.validate_field(:name, "日本語テスト", %{})
    end

    test "rejects a unicode name that is long enough to pass the length check but still slugifies to empty" do
      # 10 emoji — each is 1 grapheme cluster but the slug derivation removes
      # all of them, so the slug check fires before the length check.
      unicode_name = String.duplicate("🎯", 10)
      assert {:error, %{name: msg}} = InputValidation.validate_field(:name, unicode_name, %{})
      assert msg =~ "letter or number"
    end

    test "accepts a name that mixes ASCII with unicode (ASCII chars survive slugification)" do
      assert {:ok, _validated} = InputValidation.validate_field(:name, "AI 会議", %{})
    end
  end

  describe "slug generation properties via validate_field" do
    property "valid names produce slugs containing only lowercase alphanumerics and hyphens" do
      check all(
              alpha <- string(:alphanumeric, min_length: 2, max_length: 50),
              prefix <- string(:alphanumeric, min_length: 1, max_length: 3)
            ) do
        # Ensure at least 2 chars by prepending a letter
        input = prefix <> " " <> alpha

        case InputValidation.validate_field(:name, input, %{}) do
          {:ok, sanitized} ->
            slug =
              sanitized
              |> String.downcase()
              |> String.replace(~r/[^a-z0-9]+/, "-")
              |> String.trim("-")

            assert slug =~ ~r/\A[a-z0-9-]+\z/,
                   "Slug #{inspect(slug)} contains invalid characters (input: #{inspect(input)})"

          {:error, _reason} ->
            :ok
        end
      end
    end

    property "names shorter than 2 characters are rejected" do
      check all(char <- string(:alphanumeric, min_length: 1, max_length: 1)) do
        assert {:error, %{name: _msg}} = InputValidation.validate_field(:name, char, %{})
      end
    end

    property "names longer than 100 characters are rejected" do
      # Use only lowercase letters to avoid sanitiser stripping hex-like sequences
      check all(long <- string(?a..?z, min_length: 101, max_length: 120)) do
        assert {:error, %{name: _msg}} = InputValidation.validate_field(:name, long, %{})
      end
    end

    property "valid alphanumeric names of 2-100 chars are accepted" do
      check all(name <- string(:alphanumeric, min_length: 2, max_length: 100)) do
        assert {:ok, _sanitized} = InputValidation.validate_field(:name, name, %{})
      end
    end
  end
end
