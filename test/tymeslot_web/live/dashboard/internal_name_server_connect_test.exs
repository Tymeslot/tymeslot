defmodule TymeslotWeb.Dashboard.InternalNameServerConnectTest do
  @moduledoc """
  Connecting a self-hosted Nextcloud calendar or Nextcloud Talk server that
  runs beside Tymeslot on a Docker service name (`http://nextcloud`), from the
  dashboard. Once the operator allows private addresses for the integration,
  the connect form reaches the server over plain http and saves it; while the
  opt-in is off, the form refuses the address without contacting anything.
  """

  # Not async: the opt-ins are application config, and Mox runs in global mode
  # so the processes the connect flows spawn see the HTTP stubs.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :video
  @moduletag :live

  import Mox
  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  @calendar_server "http://nextcloud/remote.php/dav"
  @talk_server "http://nextcloud"
  @app_password "Abcde-Fghij-Klmno-Pqrst-Uvwxy"

  @propfind_calendar_response """
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response>
      <D:href>/remote.php/dav/calendars/organiser/personal/</D:href>
      <D:propstat>
        <D:prop>
          <D:displayname>Personal</D:displayname>
          <D:resourcetype>
            <D:collection/>
            <C:calendar/>
          </D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
  </D:multistatus>
  """

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    with_config(:tymeslot, :allow_private_ips_for_video, false)
    RateLimiter.clear_all()
    :ok
  end

  setup :setup_dashboard_user

  describe "Nextcloud calendar on a Docker service name" do
    @tag :capture_log
    test "discovers and saves the calendar once private calendar addresses are allowed", %{
      conn: conn,
      user: user
    } do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)
      test = self()

      stub(HTTPClientMock, :request, fn _method, url, _body, _headers, _opts ->
        send(test, {:requested, URI.parse(url).host})
        {:ok, %Req.Response{status: 207, body: @propfind_calendar_response}}
      end)

      view = open_nextcloud_form(conn)

      discovered = submit_nextcloud_discovery(view)

      assert discovered =~ "Personal"
      assert_received {:requested, "nextcloud"}

      view
      |> form("#calendar-integration-form-nextcloud")
      |> render_submit()

      assert render(view) =~ "Calendar integration added successfully"

      assert %{base_url: "http://nextcloud" <> _path} =
               Repo.get_by(CalendarIntegrationSchema, user_id: user.id, provider: "nextcloud")
    end

    test "refuses the address without contacting it while private calendar addresses are not allowed",
         %{conn: conn, user: user} do
      expect(HTTPClientMock, :request, 0, fn _method, _url, _body, _headers, _opts ->
        {:error, :unexpected}
      end)

      view = open_nextcloud_form(conn)

      assert submit_nextcloud_discovery(view) =~ "Please enter a valid server URL"
      refute has_element?(view, "#calendar-integration-form-nextcloud")
      assert Repo.get_by(CalendarIntegrationSchema, user_id: user.id) == nil
    end
  end

  describe "Nextcloud Talk on a Docker service name" do
    test "connects over plain http once private video addresses are allowed", %{
      conn: conn,
      user: user
    } do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      # Two requests: who is signed in, then what the server says about them.
      expect(HTTPClientMock, :request, 2, fn :get, url, _body, _headers, _opts ->
        assert %URI{scheme: "http", host: "nextcloud"} = URI.parse(url)

        if String.ends_with?(url, "/ocs/v2.php/cloud/user"),
          do: {:ok, %Req.Response{status: 200, body: signed_in_body()}},
          else: {:ok, %Req.Response{status: 200, body: capabilities_body()}}
      end)

      view = open_talk_form(conn)
      submit_talk_form(view)

      assert render(view) =~ "Video integration added successfully"

      assert [%{provider: "nextcloud_talk", base_url: @talk_server}] =
               Video.list_integrations(user.id)
    end

    test "asks for https without contacting the server while private video addresses are not allowed",
         %{conn: conn, user: user} do
      expect(HTTPClientMock, :request, 0, fn _method, _url, _body, _headers, _opts ->
        {:error, :unexpected}
      end)

      view = open_talk_form(conn)

      assert submit_talk_form(view) =~ "Use an https:// server URL."
      assert Video.list_integrations(user.id) == []
    end
  end

  defp open_nextcloud_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    view
    |> element("button[phx-click='connect_provider'][phx-value-provider='nextcloud']")
    |> render_click()

    view
  end

  defp submit_nextcloud_discovery(view) do
    view
    |> form("#calendar-discovery-form-nextcloud", %{
      "integration" => %{
        "name" => "Team cloud",
        "url" => @calendar_server,
        "username" => "organiser",
        "password" => @app_password
      }
    })
    |> render_submit()
  end

  defp open_talk_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    view
    |> element("button[phx-click='setup_provider'][phx-value-provider='nextcloud_talk']")
    |> render_click()

    view
  end

  defp submit_talk_form(view) do
    view
    |> form("#nextcloud-talk-video-integration-form",
      integration: %{
        name: "Team Talk",
        base_url: @talk_server,
        client_id: "organiser",
        client_secret: @app_password
      }
    )
    |> render_submit()
  end

  defp signed_in_body do
    Jason.encode!(%{"ocs" => %{"data" => %{"id" => "organiser"}}})
  end

  defp capabilities_body do
    Jason.encode!(%{
      "ocs" => %{
        "data" => %{
          "capabilities" => %{
            "spreed" => %{"version" => "25.0.0", "features" => ["conversation-creation-all"]}
          }
        }
      }
    })
  end
end
