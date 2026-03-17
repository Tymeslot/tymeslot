defmodule TymeslotWeb.Plugs.EmbedTokenPlugTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :security

  alias Tymeslot.Embed.Token
  alias TymeslotWeb.Plugs.EmbedTokenPlug

  describe "call/2" do
    test "assigns embed_token when ?embed=1 and valid username in path", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", nil}} = Token.verify(conn.assigns.embed_token)
    end

    test "uses Referer header as parent_origin when present", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> put_req_header("referer", "https://mysite.com/page")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", "https://mysite.com"}} = Token.verify(conn.assigns.embed_token)
    end

    test "Referer header takes precedence over parent-origin query param", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1&parent-origin=https://spoofed.com")
        |> put_req_header("referer", "https://real-site.com/embed-page")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", "https://real-site.com"}} = Token.verify(conn.assigns.embed_token)
    end

    test "falls back to parent-origin param when Referer is absent", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1&parent-origin=https://mysite.com")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", "https://mysite.com"}} = Token.verify(conn.assigns.embed_token)
    end

    test "assigns embed_token for nested username paths", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah/30-min-meeting")
        |> Map.put(:query_string, "embed=1")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", nil}} = Token.verify(conn.assigns.embed_token)
    end

    test "does not assign embed_token when embed param is absent", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "does not assign embed_token for reserved paths", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/dashboard")
        |> Map.put(:query_string, "embed=1")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "does not assign embed_token when embed param is 0", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=0")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "does not assign embed_token when embed param is true (only '1' triggers)", %{
      conn: conn
    } do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=true")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "does not assign embed_token when embed param is yes", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=yes")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "handles extra query params alongside embed=1", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "theme=2&embed=1&locale=de")
        |> put_req_header("referer", "https://example.com/page")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", "https://example.com"}} = Token.verify(conn.assigns.embed_token)
    end
  end
end
