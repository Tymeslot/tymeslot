defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.ClientSsrfTest do
  @moduledoc """
  Proves every Nextcloud Talk request passes through the SSRF guard. With the
  real HTTP client in production mode and a resolver that always answers with a
  private address, no request may reach the network: the `Req.Test` stub fails
  the test if one does.

  The guard also turns off redirect following, which the last test proves end
  to end with private hosts allowed: a server answering 302 must be reported,
  not followed.
  """

  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :security

  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client
  alias Tymeslot.Security.SsrfBlockedError

  @credentials %{
    base_url: "https://cloud.corp.internal",
    client_id: "organiser",
    client_secret: "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
  }

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :environment, :prod)
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    with_config(:tymeslot, :allow_private_ips_for_video, nil)
    with_config(:tymeslot, :dns_resolver_module, NextcloudTalkSsrfPrivateResolver)

    ReqTest.stub(:tymeslot_http, fn _conn ->
      flunk("a Nextcloud Talk request reached the network past the SSRF guard")
    end)

    :ok
  end

  test "every call is refused before it leaves" do
    assert {:error, %SsrfBlockedError{}} = Client.capabilities(@credentials)
    assert {:error, %SsrfBlockedError{}} = Client.create_room(@credentials, %{"roomType" => 3})

    assert {:error, %SsrfBlockedError{}} =
             Client.set_lobby(@credentials, "abc123xy", %{"state" => 1})

    assert {:error, %SsrfBlockedError{}} = Client.rename_room(@credentials, "abc123xy", "Call")
    assert {:error, %SsrfBlockedError{}} = Client.delete_room(@credentials, "abc123xy")
  end

  test "a redirect is reported and never followed, even with private hosts allowed" do
    with_config(:tymeslot, :allow_private_ips_for_video, true)

    calls = :counters.new(1, [:atomics])
    ReqTest.stub(:tymeslot_http, redirect_once(calls))

    assert {:error, {:redirected, "http://169.254.169.254/latest/meta-data/"}} =
             Client.capabilities(@credentials)

    assert :counters.get(calls, 1) == 1
  end

  defp redirect_once(calls) do
    fn conn ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) > 1 do
        flunk("the redirect was followed: a second request left the client")
      end

      conn
      |> Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
      |> Conn.send_resp(302, "")
    end
  end
end

defmodule NextcloudTalkSsrfPrivateResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end
