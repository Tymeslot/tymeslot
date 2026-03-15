defmodule TymeslotWeb.Helpers.PathUtilsTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias TymeslotWeb.Helpers.PathUtils

  describe "extract_username_from_path/1" do
    test "extracts username from scheduling path" do
      assert PathUtils.extract_username_from_path("/sarah") == "sarah"
    end

    test "extracts username from nested scheduling path" do
      assert PathUtils.extract_username_from_path("/sarah/meeting-type") == "sarah"
    end

    test "returns nil for reserved paths" do
      for reserved <- ~w(auth dashboard api dev assets docs admin healthcheck) do
        assert PathUtils.extract_username_from_path("/#{reserved}") == nil,
               "Expected nil for reserved path /#{reserved}"
      end
    end

    test "returns nil for reserved filenames" do
      assert PathUtils.extract_username_from_path("/robots.txt") == nil
      assert PathUtils.extract_username_from_path("/sitemap.xml") == nil
      assert PathUtils.extract_username_from_path("/favicon.ico") == nil
      assert PathUtils.extract_username_from_path("/embed.js") == nil
    end

    test "returns nil for digested static filenames" do
      # Digested filenames like embed-<hash>.js must not be treated as usernames.
      # This was a production bug: Plug.Static's `only` didn't catch digested
      # embed URLs, so they fell through to the router and were treated as
      # /:username routes, causing a 302 redirect.
      assert PathUtils.extract_username_from_path("/embed-77f8e1a81d47c7a5f0ed947d3d44a0e7.js") ==
               nil
    end

    test "returns nil for any path segment ending in a static file extension" do
      static_files = [
        "/app.js",
        "/style.css",
        "/manifest.json",
        "/app.js.map",
        "/assets.js.gz",
        "/logo.svg",
        "/photo.png",
        "/hero.jpg",
        "/avatar.webp",
        "/font.woff2",
        "/icon.ico"
      ]

      for path <- static_files do
        assert PathUtils.extract_username_from_path(path) == nil,
               "Expected nil for static file path #{path}"
      end
    end

    test "returns nil for empty path segment" do
      assert PathUtils.extract_username_from_path("/") == nil
    end

    test "returns nil for invalid paths" do
      assert PathUtils.extract_username_from_path("") == nil
      assert PathUtils.extract_username_from_path("no-leading-slash") == nil
    end
  end
end
