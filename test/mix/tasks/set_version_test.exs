defmodule Mix.Tasks.SetVersionTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias Mix.Tasks.SetVersion

  describe "build_cloudron_changelog/2" do
    test "returns the raw commit section verbatim when no highlights are curated" do
      raw = "* core: Some commit\n* core: Another commit"

      assert SetVersion.build_cloudron_changelog(raw, nil) == raw
    end

    test "uses curated summary and Core highlights instead of the raw commit list" do
      raw = "* core: Raw plumbing commit\n* core: More plumbing"

      curated = %{
        summary: "A focused release.",
        highlights: [{"core", "A curated headline"}, {nil, "An unscoped headline"}]
      }

      assert SetVersion.build_cloudron_changelog(raw, curated) ==
               "A focused release.\n* A curated headline\n* An unscoped headline"
    end

    test "drops SaaS-scoped highlights, since Cloudron is the Core product" do
      raw = "* core: Raw commit"

      curated = %{
        summary: "Mixed release.",
        highlights: [{"saas", "Cloud-only thing"}, {"core", "Self-hosted thing"}]
      }

      assert SetVersion.build_cloudron_changelog(raw, curated) ==
               "Mixed release.\n* Self-hosted thing"
    end

    test "always prepends [BREAKING] lines parsed from the raw section" do
      raw = "* [BREAKING] core: Removed an env var\n* core: Raw plumbing"

      curated = %{summary: nil, highlights: [{"core", "A headline"}]}

      assert SetVersion.build_cloudron_changelog(raw, curated) ==
               "* [BREAKING] core: Removed an env var\n* A headline"
    end

    test "omits the summary line when no summary is curated" do
      raw = "* core: Raw commit"

      curated = %{summary: nil, highlights: [{"core", "A headline"}]}

      assert SetVersion.build_cloudron_changelog(raw, curated) == "* A headline"
    end

    test "falls back to the raw section when all highlights are SaaS-scoped" do
      raw = "* core: Raw commit"

      curated = %{summary: "Cloud-only release.", highlights: [{"saas", "Cloud thing"}]}

      assert SetVersion.build_cloudron_changelog(raw, curated) == raw
    end

    test "uses the summary when a release has no Core commits to fall back to" do
      curated = %{summary: "A maintenance release.", highlights: []}

      assert SetVersion.build_cloudron_changelog("", curated) == "A maintenance release."
      assert SetVersion.build_cloudron_changelog("\n\n", curated) == "A maintenance release."
    end

    test "uses the summary when a release has no Core commits but SaaS-scoped highlights" do
      curated = %{summary: "A cloud release.", highlights: [{"saas", "Cloud thing"}]}

      assert SetVersion.build_cloudron_changelog("", curated) == "A cloud release."
    end

    test "renders empty when a release has neither Core commits nor a summary" do
      assert SetVersion.build_cloudron_changelog("", %{summary: nil, highlights: []}) == ""
    end
  end

  describe "ensure_changelog_present/1" do
    test "substitutes the fallback for a blank changelog" do
      fallback = "Maintenance release with behind-the-scenes improvements."

      assert SetVersion.ensure_changelog_present("") == fallback
      assert SetVersion.ensure_changelog_present("\n\n") == fallback
      assert SetVersion.ensure_changelog_present("   ") == fallback
    end

    test "passes a non-blank changelog through untouched" do
      text = "A focused release.\n* A curated headline"

      assert SetVersion.ensure_changelog_present(text) == text
    end
  end

  describe "sort_versions/1" do
    test "orders entries ascending by semver, not string order" do
      versions = %{
        "1.0.0" => %{"n" => 3},
        "0.100.0" => %{"n" => 2},
        "0.99.40" => %{"n" => 1}
      }

      assert %Jason.OrderedObject{
               values: [
                 {"0.99.40", %{"n" => 1}},
                 {"0.100.0", %{"n" => 2}},
                 {"1.0.0", %{"n" => 3}}
               ]
             } = SetVersion.sort_versions(versions)
    end

    test "round-trips through JSON preserving the ascending order" do
      versions = %{"1.4.10" => %{}, "1.4.2" => %{}, "1.4.1" => %{}}

      encoded = versions |> SetVersion.sort_versions() |> Jason.encode!()

      assert %Jason.OrderedObject{
               values: [{"1.4.1", _first}, {"1.4.2", _second}, {"1.4.10", _third}]
             } = Jason.decode!(encoded, objects: :ordered_objects)
    end
  end
end
