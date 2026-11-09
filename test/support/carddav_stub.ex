defmodule Tymeslot.Test.CardDAVStub do
  @moduledoc """
  Plays a CardDAV server behind `Req.Test` (`:tymeslot_http`): the principal,
  its `addressbook-home-set`, the address books under it and the
  `addressbook-query` REPORT, answered to requests carrying the one Basic
  credential it accepts and refused with 401 to any other.

  The REPORT answers with every card of the address book it is sent to
  whose name or address contains the request's text-match, ignoring case,
  as a server would, or with every card for an empty filter (a listing);
  each card carries a folded `PHOTO`, as SOGo sends whole cards. Each
  request is also sent to the test process as
  `{:carddav_request, method, path, body}` so a test can see what was asked.

  Options:

    * `:principal`, `:home` — the hrefs of the principal and its address
      book home.
    * `:family_name_only` — match a search's text against the last word of
      a card's name and its addresses only, as SOGo matches `FN`.
    * `:dav_root` — answer 405 to any request outside this path, as a
      Nextcloud server does outside `/remote.php/dav`.
  """

  alias Plug.Conn
  alias Req.Test, as: ReqTest

  @type card :: {name :: String.t() | nil, [email :: String.t()]}

  @doc """
  Stubs `:tymeslot_http` with a server accepting `accept_basic`
  (`"user:password"`) whose address books are `books`, a map from href to
  the cards in it, to `:refuse` for one that is listed but answers every
  search with a server error (as SOGo's global address lists do), or to
  `{:search_only, cards}` for one that refuses to be listed whole but
  answers searches.
  """
  @spec stub(
          String.t(),
          %{String.t() => [card()] | :refuse | {:search_only, [card()]}},
          keyword()
        ) ::
          :ok
  def stub(accept_basic, books, opts \\ []) do
    test = self()
    principal = Keyword.get(opts, :principal, "/principals/user/")
    home = Keyword.get(opts, :home, "/addressbooks/user/")
    dav_root = Keyword.get(opts, :dav_root, "/")
    family_name_only = Keyword.get(opts, :family_name_only, false)

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      send(test, {:carddav_request, conn.method, conn.request_path, body})

      with true <- String.starts_with?(conn.request_path, dav_root),
           ["Basic " <> encoded] <- Conn.get_req_header(conn, "authorization"),
           {:ok, ^accept_basic} <- Base.decode64(encoded) do
        respond(conn, body, principal, home, books, family_name_only)
      else
        false -> Conn.resp(conn, 405, "")
        _no_match -> Conn.resp(conn, 401, "")
      end
    end)
  end

  defp respond(conn, body, principal, home, books, family_name_only) do
    book = books[conn.request_path]
    listing? = String.contains?(body, "<card:filter/>")

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

      String.contains?(body, "addressbook-query") and book == :refuse ->
        Conn.resp(conn, 500, "")

      String.contains?(body, "addressbook-query") and listing? and match?({:search_only, _}, book) ->
        Conn.resp(conn, 500, "")

      String.contains?(body, "addressbook-query") and listing? ->
        multistatus(conn, cards_xml(conn.request_path, book || []))

      String.contains?(body, "addressbook-query") ->
        cards =
          case book do
            {:search_only, cards} -> cards
            cards -> cards || []
          end

        matches = matching(cards, text_match(body), family_name_only)
        multistatus(conn, cards_xml(conn.request_path, matches))

      true ->
        multistatus(conn, collections_xml(home, Map.keys(books)))
    end
  end

  defp text_match(body) do
    case Regex.run(~r/<card:text-match[^>]*>([^<]*)</, body) do
      [_whole, term] -> term |> unescape() |> String.downcase()
      nil -> ""
    end
  end

  defp unescape(text),
    do:
      text
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&amp;", "&")

  defp matching(cards, term, family_name_only) do
    Enum.filter(cards, fn {name, emails} ->
      name = if family_name_only, do: family_name(name), else: name || ""
      Enum.any?([name | emails], &String.contains?(String.downcase(&1), term))
    end)
  end

  defp family_name(nil), do: ""
  defp family_name(name), do: name |> String.split() |> List.last("")

  defp collections_xml(home, hrefs) do
    home_entry = """
    <response><href>#{home}</href><propstat><prop>
      <resourcetype><collection/></resourcetype>
    </prop><status>HTTP/1.1 200 OK</status></propstat></response>
    """

    books =
      Enum.map_join(hrefs, "\n", fn href ->
        """
        <response><href>#{href}</href><propstat><prop>
          <displayname>Contacts</displayname>
          <resourcetype><collection/><C:addressbook xmlns:C="urn:ietf:params:xml:ns:carddav"/></resourcetype>
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
