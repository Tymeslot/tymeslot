defmodule Tymeslot.Emails.Shared.UrlsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Urls

  # config/test.exs serves the endpoint on TEST_PORT, defaulting to 4002. The
  # expected URLs are pinned rather than rebuilt from `Endpoint.url/0`, which
  # is the call under test and so can never disagree with itself.
  @app_url "http://localhost:#{System.get_env("TEST_PORT") || "4002"}"

  describe "get_app_url/0" do
    test "returns a valid URL string" do
      url = Urls.get_app_url()

      assert url =~ ~r/^https?:\/\//
    end

    test "returns the configured scheme, host and port, with no trailing slash" do
      assert Urls.get_app_url() == @app_url
    end
  end

  describe "build_url/1" do
    test "builds URL with root path" do
      assert Urls.build_url("/") == "#{@app_url}/"
    end

    test "builds URL with specific path" do
      assert Urls.build_url("/meetings/123") == "#{@app_url}/meetings/123"
    end

    test "adds the missing leading slash rather than gluing the path to the host" do
      # Without normalisation this yields "http://localhost:4002meetings/123",
      # which is a broken link no assertion on the suffix alone would catch.
      assert Urls.build_url("meetings/123") == "#{@app_url}/meetings/123"
    end

    test "does not double the slash on a path that already has one" do
      refute Urls.build_url("/meetings/123") =~ "//meetings"
    end
  end
end
