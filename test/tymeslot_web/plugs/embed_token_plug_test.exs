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
      assert {:ok, "sarah"} = Token.verify(conn.assigns.embed_token)
    end

    test "assigns embed_token for nested username paths", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah/30-min-meeting")
        |> Map.put(:query_string, "embed=1")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, "sarah"} = Token.verify(conn.assigns.embed_token)
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
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, "sarah"} = Token.verify(conn.assigns.embed_token)
    end
  end
end
