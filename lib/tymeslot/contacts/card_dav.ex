defmodule Tymeslot.Contacts.CardDAV do
  @moduledoc """
  Reads contacts from a CardDAV server (RFC 6352), over the transport, the
  credentials and the request guards of the CalDAV connection it belongs to
  (`Tymeslot.Integrations.Calendar.CalDAV.Http`).

  Read-only and narrow on purpose: it finds the account's address books and
  asks each for the cards whose name or email address contains a search
  term, returning only names and addresses. Nothing is written to the
  server, and nothing it returns is stored.

  Discovery follows the account's principal (RFC 6352 §7.1.1), found as
  calendar discovery finds it: `current-user-principal`, then the
  principal's `addressbook-home-set`, then the address book collections
  under it. Every href the server hands back is resolved against the
  connection's base URL (`UrlBuilder.build_calendar_url/2`), so requests stay
  on the host the account owner connected.
  """

  import SweetXml, only: [sigil_x: 2, transform_by: 2]

  require Logger

  alias Tymeslot.Contacts.VCard
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalDAV.{Discovery, Http, UrlBuilder}
  alias Tymeslot.Integrations.Calendar.Utils.{SafeXml, XmlEscape}

  @type client :: %{
          required(:base_url) => String.t(),
          required(:username) => String.t(),
          required(:password) => String.t(),
          optional(atom()) => any()
        }

  @type contact :: %{name: String.t() | nil, email: String.t()}

  # Cards asked for per address book. A suggestion list shows a handful, so a
  # small page keeps the answer fast and the response small.
  @results_per_book 20
  @max_response_bytes 2_000_000
  @timeout 5_000

  @home_set_body """
  <?xml version="1.0" encoding="utf-8"?>
  <d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
    <d:prop><card:addressbook-home-set/></d:prop>
  </d:propfind>
  """

  @collections_body """
  <?xml version="1.0" encoding="utf-8"?>
  <d:propfind xmlns:d="DAV:">
    <d:prop><d:resourcetype/><d:displayname/></d:prop>
  </d:propfind>
  """

  @doc """
  The hrefs of the account's address books, or an error when the server
  has none to offer (no `addressbook-home-set`) or cannot be reached.
  """
  @spec address_books(client()) :: {:ok, [String.t()]} | {:error, term()}
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
  The contacts in the address book at `href` whose name or email address
  contains `term`, ignoring case, one entry per address.
  """
  @spec search(client(), String.t(), String.t()) :: {:ok, [contact()]} | {:error, term()}
  def search(client, href, term) do
    url = UrlBuilder.build_calendar_url(client.base_url, href)

    case Http.report(url, client.username, client.password, query_body(term),
           depth: "1",
           timeout: @timeout,
           max_response_bytes: @max_response_bytes
         ) do
      {:ok, %Req.Response{body: body}} -> parse_cards(body)
      {:error, _reason} = error -> error
    end
  end

  @doc false
  # The addressbook-query REPORT (RFC 6352 §8.6): every card whose FN or one
  # of its EMAILs contains the term, with only those two properties back.
  @spec query_body(String.t()) :: String.t()
  def query_body(term) do
    match = XmlEscape.escape(term)

    """
    <?xml version="1.0" encoding="utf-8"?>
    <card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
      <d:prop>
        <card:address-data>
          <card:prop name="FN"/>
          <card:prop name="EMAIL"/>
        </card:address-data>
      </d:prop>
      <card:filter test="anyof">
        <card:prop-filter name="FN">
          <card:text-match collation="i;unicode-casemap" match-type="contains">#{match}</card:text-match>
        </card:prop-filter>
        <card:prop-filter name="EMAIL">
          <card:text-match collation="i;unicode-casemap" match-type="contains">#{match}</card:text-match>
        </card:prop-filter>
      </card:filter>
      <card:limit><card:nresults>#{@results_per_book}</card:nresults></card:limit>
    </card:addressbook-query>
    """
  end

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
  @spec parse_address_books(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def parse_address_books(xml) do
    with {:ok, doc} <- SafeXml.parse(xml) do
      hrefs =
        doc
        |> SafeXml.xpath(
          ~x"//*[local-name()='response']"l,
          href: ~x"./*[local-name()='href']/text()"s,
          address_book?:
            transform_by(
              ~x".//*[local-name()='resourcetype']/*[local-name()='addressbook']",
              &(&1 != nil)
            )
        )
        |> Enum.filter(&(&1.address_book? and &1.href != ""))
        |> Enum.map(& &1.href)

      if hrefs == [], do: {:error, :no_address_books}, else: {:ok, hrefs}
    end
  end

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
