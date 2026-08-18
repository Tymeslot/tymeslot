defmodule TymeslotWeb.LayoutsTest do
  use ExUnit.Case, async: true

  @moduletag :components
  @moduletag :ui

  alias TymeslotWeb.Layouts

  describe "current_url/1" do
    test "uses conn.request_path when conn is present" do
      assigns = %{conn: %{request_path: "/dashboard"}}
      assert Layouts.current_url(assigns) =~ "/dashboard"
    end

    test "uses uri.path when uri is present" do
      assigns = %{uri: %URI{path: "/settings"}}
      assert Layouts.current_url(assigns) =~ "/settings"
    end

    test "falls back to request_path assign" do
      assigns = %{request_path: "/about"}
      assert Layouts.current_url(assigns) =~ "/about"
    end

    test "defaults to root path when no path info is available" do
      url = Layouts.current_url(%{})
      assert String.ends_with?(url, "/")
      refute String.ends_with?(url, "//")
    end

    test "strips trailing slashes from non-root paths" do
      assigns = %{request_path: "/docs/"}
      url = Layouts.current_url(assigns)
      assert url =~ "/docs"
      refute String.ends_with?(url, "/docs/")
    end

    test "preserves root path slash" do
      assigns = %{request_path: "/"}
      url = Layouts.current_url(assigns)
      assert String.ends_with?(url, "/")
    end

    test "does not include query parameters from conn" do
      assigns = %{conn: %{request_path: "/events"}}
      url = Layouts.current_url(assigns)
      assert url =~ "/events"
      refute url =~ "?"
    end

    test "does not include query parameters from uri" do
      assigns = %{uri: %URI{path: "/events", query: "filter=upcoming"}}
      url = Layouts.current_url(assigns)
      refute url =~ "filter"
    end

    test "prefers conn over uri when both are present" do
      assigns = %{
        conn: %{request_path: "/from-conn"},
        uri: %URI{path: "/from-uri"}
      }

      url = Layouts.current_url(assigns)
      assert url =~ "/from-conn"
    end
  end
end
