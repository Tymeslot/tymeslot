defmodule Tymeslot.Contacts.CardDAV do
  @moduledoc """
  Reads contacts from a CardDAV server (RFC 6352), over the transport, the
  credentials and the request guards of the CalDAV connection it belongs to
  (`Tymeslot.Integrations.Calendar.CalDAV.Http`).

  Read-only and narrow on purpose: it finds the account's address books
  (`address_books/1`) and lists the names and addresses in one
  (`contacts/2`). Nothing is written to the server.

  A book is listed whole and searched in Tymeslot (`Tymeslot.Contacts`)
  rather than searched on the server, because servers differ in how far
  they honour a search: SOGo, for one, matches a name filter against the
  family name only, so a contact could not be found by their given name
  there. Listing every card is the one request all of them answer alike.

  Discovery follows the account's principal (RFC 6352 §7.1.1), found as
  calendar discovery finds it: `current-user-principal`, then the
  principal's `addressbook-home-set`, then the address book collections
  under it, each with the token its contents are versioned by
  (`DAV:sync-token`, RFC 6578, or CalendarServer's `getctag`), so a book
  that has not changed need not be listed again. Every href the server
  hands back is resolved against the connection's base URL
  (`UrlBuilder.build_calendar_url/2`), so requests stay on the host the
  account owner connected.
  """

  import SweetXml, only: [sigil_x: 2, transform_by: 2]

  require Logger

  alias Tymeslot.Contacts.VCard
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalDAV.{Discovery, Http, UrlBuilder}
  alias Tymeslot.Integrations.Calendar.Utils.SafeXml

  @type client :: %{
          required(:base_url) => String.t(),
          required(:username) => String.t(),
          required(:password) => String.t(),
          optional(atom()) => any()
        }

  @type contact :: %{name: String.t() | nil, email: String.t()}

  @typedoc """
  An address book: its href, and the token its contents are versioned by,
  `nil` when the server keeps none.
  """
  @type address_book :: %{href: String.t(), token: String.t() | nil}

  @timeout 10_000

  # A listing carries every card, and some servers send each one whole
  # whatever properties are asked for, photos included. A book beyond this
  # is not synced.
  @max_listing_bytes 10_000_000

  # Properties that carry binary data, inline and base64-encoded: by far the
  # largest part of a card when present, and never needed here, so they are
  # cut from a listing before it is parsed.
  @binary_properties ~w(PHOTO LOGO SOUND KEY)

  @home_set_body """
  <?xml version="1.0" encoding="utf-8"?>
  <d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
    <d:prop><card:addressbook-home-set/></d:prop>
  </d:propfind>
  """

  @collections_body """
  <?xml version="1.0" encoding="utf-8"?>
  <d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">
    <d:prop><d:resourcetype/><d:sync-token/><cs:getctag/></d:prop>
  </d:propfind>
  """

  @doc """
  The account's address books, or an error when the server has none to
  offer (no `addressbook-home-set`) or cannot be reached.
  """
  @spec address_books(client()) :: {:ok, [address_book()]} | {:error, term()}
  def address_books(client) do
    with {:ok, principal_href} <- Discovery.current_user_principal(client),
         {:ok, %Req.Response{body: home_xml}} <-
           propfind(client, principal_href, @home_set_body, "0"),
         {:ok, home_href} <- parse_home_set(home_xml),
         {:ok, %Req.Response{body: collections_xml}} <-
           propfind(client, home_href, @collections_body, "1") do
      parse_address_books(collections_xml)
    end
  end

  @doc """
  Every contact in the address book at `href` that has an email address,
  one entry per address: an `addressbook-query` with an empty filter, which
  matches every card (RFC 6352 §10.5). `{:error, :response_too_large}` for a
  book larger than this module lists.
  """
  @spec contacts(client(), String.t()) :: {:ok, [contact()]} | {:error, term()}
  def contacts(client, href) do
    url = UrlBuilder.build_calendar_url(client.base_url, href)

    case Http.report(url, client.username, client.password, listing_body(),
           depth: "1",
           timeout: @timeout,
           max_response_bytes: @max_listing_bytes
         ) do
      {:ok, %Req.Response{body: body}} -> body |> drop_binary_properties() |> parse_cards()
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec listing_body() :: String.t()
  def listing_body do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
      <d:prop>
        <card:address-data>
          <card:prop name="FN"/>
          <card:prop name="EMAIL"/>
        </card:address-data>
      </d:prop>
      <card:filter/>
    </card:addressbook-query>
    """
  end

  @doc false
  # Cuts the binary properties, with their folded continuation lines, out of
  # the vCards in a listing. They are base64 and hold nothing the XML around
  # them could be confused with.
  @spec drop_binary_properties(String.t()) :: String.t()
  def drop_binary_properties(body) when is_binary(body) do
    Regex.replace(
      ~r/\n(?:[A-Za-z0-9-]+\.)?(?:#{Enum.join(@binary_properties, "|")})[;:][^\n]*(?:\n[ \t][^\n]*)*/i,
      body,
      ""
    )
  end

  def drop_binary_properties(body), do: body

  defp propfind(client, href, body, depth) do
    client.base_url
    |> UrlBuilder.build_calendar_url(href)
    |> Http.propfind(client.username, client.password,
      body: body,
      depth: depth,
      timeout: @timeout,
      max_attempts: 1
    )
  end

  @doc false
  @spec parse_home_set(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_home_set(xml) do
    with {:ok, doc} <- SafeXml.parse(xml) do
      case SafeXml.xpath(
             doc,
             ~x"//*[local-name()='addressbook-home-set']/*[local-name()='href']/text()"s
           ) do
        href when is_binary(href) and href != "" -> {:ok, href}
        _none -> {:error, :no_address_books}
      end
    end
  end

  @doc false
  @spec parse_address_books(String.t()) :: {:ok, [address_book()]} | {:error, term()}
  def parse_address_books(xml) do
    with {:ok, doc} <- SafeXml.parse(xml) do
      books =
        doc
        |> SafeXml.xpath(
          ~x"//*[local-name()='response']"l,
          href: ~x"./*[local-name()='href']/text()"s,
          sync_token: ~x".//*[local-name()='sync-token']/text()"s,
          ctag: ~x".//*[local-name()='getctag']/text()"s,
          address_book?:
            transform_by(
              ~x".//*[local-name()='resourcetype']/*[local-name()='addressbook']",
              &(&1 != nil)
            )
        )
        |> Enum.filter(&(&1.address_book? and &1.href != ""))
        |> Enum.map(&%{href: &1.href, token: token(&1)})

      if books == [], do: {:error, :no_address_books}, else: {:ok, books}
    end
  end

  defp token(%{sync_token: token}) when token != "", do: token
  defp token(%{ctag: ctag}) when ctag != "", do: ctag
  defp token(_book), do: nil

  @doc false
  @spec parse_cards(String.t()) :: {:ok, [contact()]} | {:error, term()}
  def parse_cards(xml) do
    with {:ok, doc} <- SafeXml.parse(xml) do
      contacts =
        doc
        |> SafeXml.xpath(~x"//*[local-name()='address-data']/text()"sl)
        |> Enum.flat_map(fn card ->
          %{name: name, emails: emails} = VCard.parse(card)
          Enum.map(emails, &%{name: name, email: &1})
        end)

      {:ok, contacts}
    end
  rescue
    e ->
      Logger.warning("CardDAV response could not be read", error: LogFormat.reason(e))
      {:error, :invalid_response}
  end
end
