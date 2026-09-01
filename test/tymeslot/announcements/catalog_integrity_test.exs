defmodule Tymeslot.Announcements.CatalogIntegrityTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :notifications

  alias Tymeslot.Announcements.Catalog

  @max_title_length 80
  @max_body_length 500
  @max_cta_label_length 40
  @max_bullet_length 100

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

    test "every cta_docs_slug is a bare slug, not a path or URL", %{entries: entries} do
      for %{key: key, cta_docs_slug: slug} when is_binary(slug) <- entries do
        assert slug != "", "blank cta_docs_slug for #{key}"

        refute String.starts_with?(slug, "/"),
               "cta_docs_slug #{inspect(slug)} for #{key} must not start with /; " <>
                 "it is composed onto :docs_article_base_url, so store just the slug"

        refute Regex.match?(~r{https?://}i, slug),
               "cta_docs_slug #{inspect(slug)} for #{key} looks like an absolute URL; " <>
                 "store just the slug — the base URL comes from :docs_article_base_url"
      end
    end

    test "cta_label and cta_docs_slug are present together or absent together", %{
      entries: entries
    } do
      for entry <- entries do
        assert is_nil(entry.cta_label) == is_nil(entry.cta_docs_slug),
               "cta_label/cta_docs_slug mismatch for #{entry.key}: #{inspect(entry.cta_label)} / " <>
                 "#{inspect(entry.cta_docs_slug)}. The component renders a CTA only when both are set."
      end
    end

    test "every bullet is a non-empty binary that fits one line", %{entries: entries} do
      for %{key: key, bullets: bullets} <- entries, bullet <- bullets do
        assert is_binary(bullet) and bullet != "", "blank bullet for #{key}"

        assert String.length(bullet) <= @max_bullet_length,
               "bullet for #{key} is #{String.length(bullet)} chars; " <>
                 "max is #{@max_bullet_length}. Long bullets wrap awkwardly in the modal."
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

    test "every expires_at, when set, is a UTC DateTime after published_at", %{entries: entries} do
      for %{expires_at: %DateTime{} = expires_at} = entry <- entries do
        assert expires_at.time_zone == "Etc/UTC",
               "expires_at for #{entry.key} must be a UTC DateTime; got #{inspect(expires_at)}"

        assert DateTime.after?(expires_at, entry.published_at),
               "expires_at for #{entry.key} must be after published_at; the entry would never be shown."
      end
    end
  end
end
