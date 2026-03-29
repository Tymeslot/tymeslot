defmodule TymeslotWeb.Plugs.ThemePlugTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs

  alias TymeslotWeb.Plugs.ThemePlug

  describe "init/1" do
    test "passes options through unchanged" do
      assert ThemePlug.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2" do
    test "extracts theme_id from /scheduling/theme/:id path", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_session()
        |> Map.put(:request_path, "/scheduling/theme/42")
        |> ThemePlug.call([])

      assert conn.assigns[:theme_id] == "42"
      assert get_session(conn, :theme_id) == "42"
    end

    test "extracts theme_id from /theme/:id path", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_session()
        |> Map.put(:request_path, "/theme/7")
        |> ThemePlug.call([])

      assert conn.assigns[:theme_id] == "7"
      assert get_session(conn, :theme_id) == "7"
    end

    test "returns conn unchanged for unrelated path", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_session()
        |> Map.put(:request_path, "/dashboard/settings")
        |> ThemePlug.call([])

      refute Map.has_key?(conn.assigns, :theme_id)
    end

    test "does not match non-numeric theme ID", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_session()
        |> Map.put(:request_path, "/scheduling/theme/abc")
        |> ThemePlug.call([])

      refute Map.has_key?(conn.assigns, :theme_id)
    end

    test "extracts theme_id from nested scheduling path", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_session()
        |> Map.put(:request_path, "/scheduling/theme/99/some/nested/path")
        |> ThemePlug.call([])

      assert conn.assigns[:theme_id] == "99"
      assert get_session(conn, :theme_id) == "99"
    end

    test "does not halt the connection", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_session()
        |> Map.put(:request_path, "/scheduling/theme/1")
        |> ThemePlug.call([])

      refute conn.halted
    end

    test "/theme/:id must be at the start of the path", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_session()
        |> Map.put(:request_path, "/other/theme/5")
        |> ThemePlug.call([])

      refute Map.has_key?(conn.assigns, :theme_id)
    end
  end
end
