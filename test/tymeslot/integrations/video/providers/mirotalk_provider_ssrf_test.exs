defmodule Tymeslot.Integrations.Video.Providers.MiroTalkProviderSsrfTest do
  @moduledoc """
  Verifies that the MiroTalk call sites in `MiroTalkProvider` and
  `JoinUrlBuilder` pass `ssrf_protect: true` to the HTTP client.

  Each test pins the environment to `:prod` and injects a DNS resolver that
  always returns a private address.  Removing `ssrf_protect: true` from any
  call site would allow the request to reach the Req.Test stub, which calls
  `flunk/1` — making that test fail.

  Tests cover:
  - `MiroTalkProvider.test_connection/2` (the `/api/v1/meeting` call site in
    `mirotalk_provider.ex`)
  - `MiroTalkProvider.create_meeting_room/1` (the `/api/v1/meeting` POST call
    site in `mirotalk_provider.ex`)
  - `JoinUrlBuilder.create_join_url_via_api/5` (the `/api/v1/join` POST call
    site in `join_url_builder.ex`)
  - `JoinUrlBuilder.create_join_url_legacy/4` (the legacy `/api/v1/join` call
    site in `join_url_builder.ex`)
  """

  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :security

  import Tymeslot.ConfigTestHelpers

  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Video.Providers.MiroTalk.JoinUrlBuilder
  alias Tymeslot.Integrations.Video.Providers.MiroTalkProvider
  alias Tymeslot.Security.SsrfBlockedError

  setup do
    # Use the real HTTPClient so the ssrf_protect option is evaluated.
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :environment, :prod)
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    with_config(:tymeslot, :dns_resolver_module, MiroTalkSsrfPrivateResolver)
    :ok
  end

  @private_base_url "https://mirotalk.corp.internal"
  @config %{api_key: "test-key", base_url: @private_base_url}

  describe "MiroTalkProvider.test_connection/2 call site threads ssrf_protect: true" do
    test "blocks the connection test when the MiroTalk host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk(
          "network request must not reach the MiroTalk server — ssrf_protect: true is missing"
        )
      end)

      # test_connection calls validate_base_url first, which uses string-based
      # UrlValidation (not the DNS resolver).  The private base URL passes that
      # check because it uses a hostname, not a bare IP literal.  The SSRF guard
      # then fires at the HTTP layer, returning SsrfBlockedError — which
      # handle_http_error maps to a generic connection failure message.
      assert {:error, message} = MiroTalkProvider.test_connection(@config)
      assert is_binary(message)
    end
  end

  describe "MiroTalkProvider.create_meeting_room/1 call site threads ssrf_protect: true" do
    test "blocks the create-room request when the MiroTalk host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk(
          "network request must not reach the MiroTalk server — ssrf_protect: true is missing"
        )
      end)

      # SsrfBlockedError flows through the {:error, reason} branch of
      # create_meeting_room, which returns {:error, %SsrfBlockedError{}}.
      assert {:error, %SsrfBlockedError{}} = MiroTalkProvider.create_meeting_room(@config)
    end
  end

  describe "JoinUrlBuilder.create_join_url_via_api/5 call site threads ssrf_protect: true" do
    test "blocks the join URL API call when the MiroTalk host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk(
          "network request must not reach the MiroTalk server — ssrf_protect: true is missing"
        )
      end)

      # HttpHelpers.try_https_then_http detects SsrfBlockedError as terminal and
      # does not fall back to HTTP.  handle_join_api_response passes the error
      # through its {:error, reason} clause.
      assert {:error, %SsrfBlockedError{}} =
               JoinUrlBuilder.create_join_url_via_api(
                 @config,
                 "room-abc",
                 "Alice",
                 "alice@example.com",
                 "attendee"
               )
    end
  end

  describe "JoinUrlBuilder.create_join_url_legacy/4 call site threads ssrf_protect: true" do
    test "blocks the legacy join URL API call when the MiroTalk host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk(
          "network request must not reach the MiroTalk server — ssrf_protect: true is missing"
        )
      end)

      assert {:error, %SsrfBlockedError{}} =
               JoinUrlBuilder.create_join_url_legacy(
                 @config,
                 "room-abc",
                 "Alice",
                 "alice@example.com"
               )
    end
  end
end

defmodule MiroTalkSsrfPrivateResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end
