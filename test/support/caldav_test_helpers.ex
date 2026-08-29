defmodule Tymeslot.CalDAVTestHelpers do
  @moduledoc """
  Shared test helpers for CalDAV-based calendar providers.

  Provides common assertions for CalDAV, Nextcloud, and Radicale providers, and
  builders for the PROPFIND responses the RFC 4791 discovery chain walks.
  """

  import ExUnit.Assertions

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
end
