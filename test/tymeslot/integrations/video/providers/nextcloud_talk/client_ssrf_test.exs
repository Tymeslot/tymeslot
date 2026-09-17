defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.ClientSsrfTest do
  @moduledoc """
  Proves every Nextcloud Talk request passes through the SSRF guard. With the
  real HTTP client in production mode and a resolver that always answers with a
  private address, no request may reach the network: the `Req.Test` stub fails
  the test if one does.
  """

  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :security

  import Tymeslot.ConfigTestHelpers

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
    with_config(:tymeslot, :allow_private_ips_for_video, false)
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
end

defmodule NextcloudTalkSsrfPrivateResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end
