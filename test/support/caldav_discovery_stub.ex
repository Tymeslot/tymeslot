defmodule Tymeslot.Test.CalDAVDiscoveryStub do
  @moduledoc """
  Plays a CalDAV server's discovery behind `Req.Test` (`:tymeslot_http`):
  the principal, the calendar home and its calendars, answered to requests
  carrying the one Basic credential it accepts and refused with 401 to any
  other. For tests that drive discovery over the real HTTP client, such as
  a reconnect.
  """

  alias Plug.Conn
  alias Req.Test, as: ReqTest

  @doc """
  Stubs `:tymeslot_http` with a server accepting `accept_basic`
  (`"user:password"`) and listing `calendars`, `{href, name}` pairs.
  """
  @spec stub(String.t(), String.t(), String.t(), [{String.t(), String.t()}]) :: :ok
  def stub(accept_basic, principal_path, home_set_path, calendars) do
    ReqTest.stub(:tymeslot_http, fn http_conn ->
      with ["Basic " <> encoded] <- Conn.get_req_header(http_conn, "authorization"),
           {:ok, ^accept_basic} <- Base.decode64(encoded) do
        respond_caldav(http_conn, principal_path, home_set_path, calendars)
      else
        _no_match -> Conn.resp(http_conn, 401, "")
      end
    end)
  end

  defp respond_caldav(conn, principal_path, home_set_path, calendars) do
    {:ok, body, conn} = Conn.read_body(conn)

    cond do
      String.contains?(body, "current-user-principal") ->
        xml_multistatus(conn, """
          <response>
            <href>#{conn.request_path}</href>
            <propstat>
              <prop>
                <current-user-principal xmlns="DAV:"><href>#{principal_path}</href></current-user-principal>
              </prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
          </response>
        """)

      String.contains?(body, "calendar-home-set") ->
        xml_multistatus(conn, """
          <response>
            <href>#{conn.request_path}</href>
            <propstat>
              <prop>
                <calendar-home-set xmlns="urn:ietf:params:xml:ns:caldav">
                  <href xmlns="DAV:">#{home_set_path}</href>
                </calendar-home-set>
              </prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
          </response>
        """)

      true ->
        # Calendar listing — emit one <response> per requested calendar.
        inner =
          Enum.map_join(calendars, "\n", fn {href, name} ->
            """
              <response>
                <href>#{href}</href>
                <propstat>
                  <prop>
                    <displayname>#{name}</displayname>
                    <resourcetype>
                      <collection/>
                      <calendar xmlns="urn:ietf:params:xml:ns:caldav"/>
                    </resourcetype>
                  </prop>
                  <status>HTTP/1.1 200 OK</status>
                </propstat>
              </response>
            """
          end)

        xml_multistatus(conn, inner)
    end
  end

  defp xml_multistatus(conn, inner) do
    xml = ~s|<?xml version="1.0"?><multistatus xmlns="DAV:">#{inner}</multistatus>|

    conn
    |> Conn.put_resp_header("content-type", "application/xml")
    |> Conn.resp(207, xml)
  end
end
