defmodule Tymeslot.Announcements.CatalogIntegrityTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Tymeslot.Announcements.Catalog

  @max_title_length 80
  @max_body_length 500
  @max_cta_label_length 40

  setup do
    {:ok, entries: Catalog.list()}
  end

  describe "Tymeslot.Announcements.Catalog integrity" do
    test "every key is globally unique", %{entries: entries} do
      keys = Enum.map(entries, & &1.key)
      duplicates = keys -- Enum.uniq(keys)

      assert duplicates == [],
             "duplicate announcement keys: #{inspect(duplicates)}. " <>
               "Keys are the identity stored in user_seen_announcements; collisions cause " <>
               "users to never have one of the duplicates marked seen."
    end

    test "every key is a non-empty binary", %{entries: entries} do
      for entry <- entries do
        assert is_binary(entry.key) and entry.key != "", "blank key on entry: #{inspect(entry)}"
      end
    end

    test "every title is non-empty and fits the modal header", %{entries: entries} do
      for entry <- entries do
        assert is_binary(entry.title) and entry.title != "",
               "blank title for #{entry.key}"

        assert String.length(entry.title) <= @max_title_length,
               "title for #{entry.key} is #{String.length(entry.title)} chars; " <>
                 "max is #{@max_title_length}. Long titles overflow the modal header."
      end
    end

    test "every body is non-empty and fits the modal", %{entries: entries} do
      for entry <- entries do
        assert is_binary(entry.body) and entry.body != "",
               "blank body for #{entry.key}"

        assert String.length(entry.body) <= @max_body_length,
               "body for #{entry.key} is #{String.length(entry.body)} chars; " <>
                 "max is #{@max_body_length}. Long bodies push the modal off-screen."
      end
    end

    test "every image_path resolves to a file under priv/static", %{entries: entries} do
      static_root = Path.join(:code.priv_dir(:tymeslot), "static")

      for %{key: key, image_path: path} when is_binary(path) <- entries do
        absolute = Path.join(static_root, String.trim_leading(path, "/"))

        assert File.exists?(absolute),
               "image_path #{inspect(path)} for #{key} does not exist at #{absolute}"
      end
    end

    test "every cta_path is a local path starting with a single /", %{entries: entries} do
      for %{key: key, cta_path: path} when is_binary(path) <- entries do
        assert String.starts_with?(path, "/"),
               "cta_path #{inspect(path)} for #{key} must start with /"

        refute String.starts_with?(path, "//"),
               "cta_path #{inspect(path)} for #{key} must not start with //; " <>
                 "Phoenix push_navigate rejects protocol-relative URLs"

        refute Regex.match?(~r/^\/?https?:\/\//i, path),
               "cta_path #{inspect(path)} for #{key} looks like an absolute URL; " <>
                 "use a local path instead"
      end
    end

    test "cta_label and cta_path are present together or absent together", %{entries: entries} do
      for entry <- entries do
        assert is_nil(entry.cta_label) == is_nil(entry.cta_path),
               "cta_label/cta_path mismatch for #{entry.key}: #{inspect(entry.cta_label)} / " <>
                 "#{inspect(entry.cta_path)}. The component renders a CTA only when both are set."
      end
    end

    test "every cta_label is non-empty and fits the button", %{entries: entries} do
      for %{key: key, cta_label: label} when is_binary(label) <- entries do
        assert label != "", "blank cta_label for #{key}"

        assert String.length(label) <= @max_cta_label_length,
               "cta_label for #{key} is #{String.length(label)} chars; " <>
                 "max is #{@max_cta_label_length}"
      end
    end

    test "every published_at is a UTC DateTime", %{entries: entries} do
      for entry <- entries do
        assert match?(%DateTime{time_zone: "Etc/UTC"}, entry.published_at),
               "published_at for #{entry.key} must be a UTC DateTime; got #{inspect(entry.published_at)}"
      end
    end
  end
end
