defmodule TymeslotWeb.Live.Scheduling.PreviewModeTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :scheduling
  @moduletag :unit

  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Live.Scheduling.PreviewToken

  describe "claimed?/1" do
    test "an explicit preview claim counts" do
      assert PreviewMode.claimed?(%{"preview" => "true"})
      assert PreviewMode.claimed?(%{"preview" => "1"})
    end

    test "the claim is the key, not its value, so an empty one still counts" do
      # `?preview=` with nothing after it is still someone asking for preview
      # display. Reading the value instead would let a truncated link render as
      # a normal public page while the owner believes they are simulating.
      assert PreviewMode.claimed?(%{"preview" => ""})
    end

    test "a theme selector is not a preview claim" do
      # The regression that made #84 possible. `?theme=` picks which theme
      # renders on a public page; anyone can type it, and the locale switcher
      # used to add it unasked. Counting it as a claim failed real bookings
      # closed.
      refute PreviewMode.claimed?(%{"theme" => "2"})
      refute PreviewMode.claimed?(%{"theme" => "1", "locale" => "fr"})
    end

    test "an ordinary visitor's params are not a claim" do
      refute PreviewMode.claimed?(%{})
      refute PreviewMode.claimed?(%{"username" => "alice", "locale" => "de"})
      refute PreviewMode.claimed?(%{"preview_token" => "orphaned"})
    end
  end

  describe "owner_path/3" do
    test "carries both halves of the contract: the claim and a valid token" do
      path = PreviewMode.owner_path("alice", 42)

      %{query: query} = URI.parse(path)
      params = URI.decode_query(query)

      assert String.starts_with?(path, "/alice?")
      assert params["preview"] == "true"

      # The token must actually verify against this owner. A link that carries
      # a claim but no usable token is the dashboard bug this replaces: the
      # owner's own test booking hit the fail-closed branch and vanished.
      assert PreviewToken.owner?(params["preview_token"], 42)
    end

    test "the token is bound to the owner, so it does not authorise another page" do
      path = PreviewMode.owner_path("alice", 42)
      %{query: query} = URI.parse(path)
      token = URI.decode_query(query)["preview_token"]

      refute PreviewToken.owner?(token, 43)
    end

    test "includes the previewed theme when one is given" do
      path = PreviewMode.owner_path("alice", 42, theme: "2")
      %{query: query} = URI.parse(path)

      assert URI.decode_query(query)["theme"] == "2"
    end

    test "omits the theme when none is given, so the stored theme renders" do
      path = PreviewMode.owner_path("alice", 42)
      %{query: query} = URI.parse(path)

      refute Map.has_key?(URI.decode_query(query), "theme")
      refute path =~ "theme="
    end

    test "omits an empty theme rather than emitting a blank selector" do
      nil_path = PreviewMode.owner_path("alice", 42, theme: nil)
      empty_path = PreviewMode.owner_path("alice", 42, theme: "")

      refute Map.has_key?(URI.decode_query(URI.parse(nil_path).query), "theme")
      refute Map.has_key?(URI.decode_query(URI.parse(empty_path).query), "theme")
      refute empty_path =~ "theme="
    end

    test "encodes a username that needs escaping" do
      path = PreviewMode.owner_path("john.doe", 42, theme: "1")

      assert String.starts_with?(path, "/john.doe?")
    end
  end

  describe "owner_url/3" do
    test "is the absolute form of the same path" do
      url = PreviewMode.owner_url("alice", 42, theme: "2")
      %URI{scheme: scheme, host: host, path: path} = URI.parse(url)

      # Pinned to what `config/test.exs` sets on the endpoint, so this fails if
      # the URL stops being absolute rather than tracking whatever it produces.
      assert scheme == "http"
      assert host == "localhost"
      assert path == "/alice"
      assert url =~ "preview=true"
      assert url =~ "theme=2"
    end
  end
end
