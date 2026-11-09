defmodule Tymeslot.Test.CardDAVStub do
  @moduledoc """
  Plays a CardDAV server behind `Req.Test` (`:tymeslot_http`): the principal,
  its `addressbook-home-set`, the address books under it with their sync
  tokens, and the `addressbook-query` REPORT listing every card of a book,
  answered to requests carrying the one Basic credential it accepts and
  refused with 401 to any other. Each card carries a folded `PHOTO`, as SOGo
  sends whole cards whatever is asked for.

  Each request is also sent to the test process as
  `{:carddav_request, method, path, body}` so a test can see what was asked.

  Options:

    * `:principal`, `:home` — the hrefs of the principal and its address
      book home.
    * `:tokens` — a map from a book's href to the sync token it reports;
      a book without one reports none.
    * `:dav_root` — answer 405 to any request outside this path, as a
      Nextcloud server does outside `/remote.php/dav`.
  """

  alias Plug.Conn
  alias Req.Test, as: ReqTest

  @type card :: {name :: String.t() | nil, [email :: String.t()]}

  @doc """
  Stubs `:tymeslot_http` with a server accepting `accept_basic`
  (`"user:password"`) whose address books are `books`, a map from href to
  the cards in it, or to `:refuse` for one that is listed but answers a
  REPORT with a server error (as SOGo's global address lists do).
  """
  @spec stub(String.t(), %{String.t() => [card()] | :refuse}, keyword()) :: :ok
  def stub(accept_basic, books, opts \\ []) do
    test = self()
    principal = Keyword.get(opts, :principal, "/principals/user/")
    home = Keyword.get(opts, :home, "/addressbooks/user/")
    tokens = Keyword.get(opts, :tokens, %{})
    dav_root = Keyword.get(opts, :dav_root, "/")

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      send(test, {:carddav_request, conn.method, conn.request_path, body})

      with true <- String.starts_with?(conn.request_path, dav_root),
           ["Basic " <> encoded] <- Conn.get_req_header(conn, "authorization"),
           {:ok, ^accept_basic} <- Base.decode64(encoded) do
        respond(conn, body, principal, home, books, tokens)
      else
        false -> Conn.resp(conn, 405, "")
        _no_match -> Conn.resp(conn, 401, "")
      end
    end)
  end

  defp respond(conn, body, principal, home, books, tokens) do
    cond do
      String.contains?(body, "current-user-principal") ->
        multistatus(conn, """
        <response><href>#{conn.request_path}</href><propstat><prop>
          <current-user-principal><href>#{principal}</href></current-user-principal>
        </prop><status>HTTP/1.1 200 OK</status></propstat></response>
        """)

      String.contains?(body, "addressbook-home-set") ->
        multistatus(conn, """
        <response><href>#{principal}</href><propstat><prop>
          <C:addressbook-home-set xmlns:C="urn:ietf:params:xml:ns:carddav"><href>#{home}</href></C:addressbook-home-set>
        </prop><status>HTTP/1.1 200 OK</status></propstat></response>
        """)

      String.contains?(body, "addressbook-query") and books[conn.request_path] == :refuse ->
        Conn.resp(conn, 500, "")

      String.contains?(body, "addressbook-query") ->
        multistatus(conn, cards_xml(conn.request_path, Map.get(books, conn.request_path, [])))

      true ->
        multistatus(conn, collections_xml(home, Map.keys(books), tokens))
    end
  end

  defp collections_xml(home, hrefs, tokens) do
    home_entry = """
    <response><href>#{home}</href><propstat><prop>
      <resourcetype><collection/></resourcetype>
    </prop><status>HTTP/1.1 200 OK</status></propstat></response>
    """

    books =
      Enum.map_join(hrefs, "\n", fn href ->
        token =
          case tokens[href] do
            nil -> ""
            token -> "<sync-token>#{token}</sync-token>"
          end

        """
        <response><href>#{href}</href><propstat><prop>
          <resourcetype><collection/><C:addressbook xmlns:C="urn:ietf:params:xml:ns:carddav"/></resourcetype>
          #{token}
        </prop><status>HTTP/1.1 200 OK</status></propstat></response>
        """
      end)

    home_entry <> books
  end

  defp cards_xml(path, cards) do
    cards
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {{name, emails}, index} ->
      lines =
        ["BEGIN:VCARD", "VERSION:3.0"] ++
          if(name, do: ["FN:#{name}"], else: []) ++
          ["PHOTO;ENCODING=b;TYPE=JPEG:/9j/4AAQSkZJRgABAQ", " AAAQABAAD/2wBDAAgGBgcGBQgH"] ++
          Enum.map(emails, &"EMAIL;TYPE=INTERNET:#{&1}") ++ ["END:VCARD"]

      """
      <response><href>#{path}#{index}.vcf</href><propstat><prop>
        <C:address-data xmlns:C="urn:ietf:params:xml:ns:carddav">#{Enum.join(lines, "\r\n")}</C:address-data>
      </prop><status>HTTP/1.1 200 OK</status></propstat></response>
      """
    end)
  end

  defp multistatus(conn, inner) do
    conn
    |> Conn.put_resp_header("content-type", "application/xml; charset=utf-8")
    |> Conn.resp(207, ~s|<?xml version="1.0"?><multistatus xmlns="DAV:">#{inner}</multistatus>|)
  end
end
