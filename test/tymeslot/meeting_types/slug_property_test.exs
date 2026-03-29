defmodule Tymeslot.MeetingTypes.SlugPropertyTest do
  @moduledoc """
  Property-based tests for slug generation logic used in meeting type validation.

  The slug transformation is inlined here because it is embedded in a larger
  validation function (`InputValidation.validate_meeting_name/2`) and cannot
  be called in isolation.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :meeting_types
  use ExUnitProperties

  # Mirror of the slug logic from InputValidation.validate_meeting_name/2
  defp slugify(input) when is_binary(input) do
    input
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  describe "slug generation properties" do
    property "slug contains only lowercase alphanumerics and hyphens" do
      check all(input <- string(:printable, min_length: 1)) do
        slug = slugify(input)

        if slug != "" do
          assert slug =~ ~r/\A[a-z0-9-]+\z/,
                 "Slug #{inspect(slug)} contains invalid characters (input: #{inspect(input)})"
        end
      end
    end

    property "slug never starts or ends with a hyphen" do
      check all(input <- string(:printable, min_length: 1)) do
        slug = slugify(input)

        if slug != "" do
          refute String.starts_with?(slug, "-"),
                 "Slug #{inspect(slug)} starts with a hyphen (input: #{inspect(input)})"

          refute String.ends_with?(slug, "-"),
                 "Slug #{inspect(slug)} ends with a hyphen (input: #{inspect(input)})"
        end
      end
    end

    property "slug is idempotent (slugifying a slug returns the same slug)" do
      check all(input <- string(:printable, min_length: 1)) do
        slug = slugify(input)
        assert slugify(slug) == slug
      end
    end

    property "slug is always lowercase" do
      check all(input <- string(:printable, min_length: 1)) do
        slug = slugify(input)
        assert slug == String.downcase(slug)
      end
    end
  end
end
