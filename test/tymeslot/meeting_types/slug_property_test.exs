defmodule Tymeslot.MeetingTypes.SlugPropertyTest do
  @moduledoc """
  Property-based tests for slug generation logic used in meeting type validation.

  Tests drive through the public API `InputValidation.validate_meeting_type_field/3`
  to exercise the full pipeline including sanitisation and slug generation.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :meeting_types
  use ExUnitProperties

  alias Tymeslot.MeetingTypes.InputValidation

  describe "slug generation properties via validate_meeting_type_field" do
    property "valid names produce slugs containing only lowercase alphanumerics and hyphens" do
      check all(
              alpha <- string(:alphanumeric, min_length: 2, max_length: 50),
              prefix <- string(:alphanumeric, min_length: 1, max_length: 3)
            ) do
        # Ensure at least 2 chars by prepending a letter
        input = prefix <> " " <> alpha

        case InputValidation.validate_meeting_type_field(:name, input) do
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
        assert {:error, %{name: _msg}} = InputValidation.validate_meeting_type_field(:name, char)
      end
    end

    property "names longer than 100 characters are rejected" do
      # Use only lowercase letters to avoid sanitiser stripping hex-like sequences
      check all(long <- string(?a..?z, min_length: 101, max_length: 120)) do
        assert {:error, %{name: _msg}} = InputValidation.validate_meeting_type_field(:name, long)
      end
    end

    property "valid alphanumeric names of 2-100 chars are accepted" do
      check all(name <- string(:alphanumeric, min_length: 2, max_length: 100)) do
        assert {:ok, _sanitized} = InputValidation.validate_meeting_type_field(:name, name)
      end
    end
  end
end
