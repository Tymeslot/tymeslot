defmodule TymeslotWeb.Dashboard.VideoSettings.MiroTalkInternalNameTest do
  @moduledoc """
  A self-hosted MiroTalk server beside Tymeslot on a Docker service name
  (`http://mirotalk`) can be connected once the operator allows private video
  addresses (`ALLOW_PRIVATE_IPS_FOR_VIDEO`). While the opt-in is off, the
  server address field still asks for a full domain, on blur and on submit.

  The same server address check runs on blur for every video provider form
  that validates its address there, so it is exercised directly as well.
  """

  # Not async: the opt-in is application config, and Mox runs in global mode.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :video
  @moduletag :integrations
  @moduletag :live

  import Mox
  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]
  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.InputValidation
  alias Tymeslot.Security.RateLimiter

  @server "http://mirotalk"
  @refused "Please enter a valid server URL"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    with_config(:tymeslot, :allow_private_ips_for_video, false)
    RateLimiter.clear_all()
    :ok
  end

  setup :setup_dashboard_user

  describe "the server address field check" do
    test "accepts a Docker service name once private video addresses are allowed" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      assert {:ok, @server} = InputValidation.validate_single_field(:base_url, @server)

      assert {:ok, "http://mirotalk:3010"} =
               InputValidation.validate_single_field(:base_url, "http://mirotalk:3010")
    end

    test "asks for a full domain while private video addresses are not allowed" do
      assert {:error, message} = InputValidation.validate_single_field(:base_url, @server)
      assert message =~ @refused
    end

    test "still refuses a single label that is not a host name" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      assert {:error, message} =
               InputValidation.validate_single_field(:base_url, "http://mirotalk-")

      assert message =~ @refused
    end
  end

  describe "connecting MiroTalk on a Docker service name" do
    test "is accepted on blur and saved once private video addresses are allowed", %{
      conn: conn,
      user: user
    } do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      stub(HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "{}"}}
      end)

      view = open_mirotalk_form(conn)

      view |> element("#mirotalk_base_url") |> render_blur(%{"value" => @server})
      refute has_element?(view, "#mirotalk_base_url-error")

      submit_mirotalk_form(view)

      assert render(view) =~ "Video integration added successfully"
      assert [%{provider: "mirotalk", base_url: @server}] = Video.list_integrations(user.id)
    end

    test "is refused on blur and on submit while private video addresses are not allowed", %{
      conn: conn,
      user: user
    } do
      expect(HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        {:error, :unexpected}
      end)

      view = open_mirotalk_form(conn)

      view |> element("#mirotalk_base_url") |> render_blur(%{"value" => @server})
      assert has_element?(view, "#mirotalk_base_url-error p.form-error", @refused)

      submit_mirotalk_form(view)

      assert has_element?(view, "#mirotalk_base_url-error p.form-error", @refused)
      assert Video.list_integrations(user.id) == []
    end
  end

  defp open_mirotalk_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    view
    |> element("button[phx-click='setup_provider'][phx-value-provider='mirotalk']")
    |> render_click()

    view
  end

  defp submit_mirotalk_form(view) do
    view
    |> form("#mirotalk-config-modal form", %{
      "integration" => %{
        "name" => "Team MiroTalk",
        "base_url" => @server,
        "api_key" => "secret-key-long-enough"
      }
    })
    |> render_submit()
  end
end
