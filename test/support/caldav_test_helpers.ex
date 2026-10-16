defmodule Tymeslot.CalDAVTestHelpers do
  @moduledoc """
  Shared test helpers for CalDAV-based calendar providers.

  Provides common assertions for CalDAV, Nextcloud, and Radicale providers, and
  builders for the PROPFIND responses the RFC 4791 discovery chain walks.
  """

  import ExUnit.Assertions

  alias Plug.Conn

  @doc """
  Asserts that a schema has the required CalDAV base fields.
  """
  @spec assert_has_caldav_base_fields(map()) :: :ok
  def assert_has_caldav_base_fields(schema) do
    assert schema[:base_url][:type] == :string
    assert schema[:base_url][:required] == true
    assert schema[:username][:type] == :string
    assert schema[:username][:required] == true
    assert schema[:password][:type] == :string
    assert schema[:password][:required] == true

    :ok
  end

  @doc """
  A `current-user-principal` PROPFIND response pointing at `href`.
  """
  @spec principal_xml(String.t()) :: String.t()
  def principal_xml(href) do
    """
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:propstat>
          <D:prop>
            <D:current-user-principal><D:href>#{href}</D:href></D:current-user-principal>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
  end

  @doc """
  A `calendar-home-set` PROPFIND response pointing at `href`.
  """
  @spec calendar_home_set_xml(String.t()) :: String.t()
  def calendar_home_set_xml(href) do
    """
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:propstat>
          <D:prop>
            <C:calendar-home-set><D:href>#{href}</D:href></C:calendar-home-set>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
  end

  @doc """
  A principal's `calendar-user-address-set` PROPFIND response, the first of
  `addresses` marked preferred, the way Open-Xchange answers.
  """
  @spec calendar_user_address_set_xml([String.t()]) :: String.t()
  def calendar_user_address_set_xml(addresses) do
    hrefs =
      addresses
      |> Enum.with_index()
      |> Enum.map_join(fn
        {address, 0} -> ~s(<D:href preferred="1">mailto:#{address}</D:href>)
        {address, _index} -> "<D:href>mailto:#{address}</D:href>"
      end)

    """
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>/principals/users/3</D:href>
        <D:propstat>
          <D:prop>
            <C:calendar-user-address-set>#{hrefs}<D:href>/principals/users/3</D:href></C:calendar-user-address-set>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
  end

  @doc """
  Answers the two PROPFINDs `CalDAV.Discovery.calendar_user_addresses/1`
  sends, as an Open-Xchange account owning `addresses` would, for a
  `Req.Test` stub that still answers the test's other requests itself:

      ReqTest.stub(:tymeslot_http, fn
        %{method: "PROPFIND"} = conn -> CalDAVTestHelpers.answer_address_lookup(conn, addresses)
        conn -> ...
      end)
  """
  @spec answer_address_lookup(Conn.t(), [String.t()]) :: Conn.t()
  def answer_address_lookup(conn, addresses) do
    {:ok, body, conn} = Conn.read_body(conn)

    xml =
      if body =~ "calendar-user-address-set",
        do: calendar_user_address_set_xml(addresses),
        else: principal_xml("/principals/users/3")

    Conn.send_resp(conn, 207, xml)
  end
end
