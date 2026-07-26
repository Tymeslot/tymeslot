defmodule Tymeslot.Integrations.Calendar.DiscoveryTest do
  # async: false — CalDAV discovery runs HTTP calls inside a circuit-breaker
  # GenServer; in async (private) mode that process has no Mox allowance and
  # the stub is bypassed, causing the success branch to never fire.
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Security.Encryption
  import Tymeslot.Factory
  import Mox

  setup :verify_on_exit!

  describe "discover_calendars_for_integration/1" do
    test "discovers for google provider" do
      integration = insert(:calendar_integration, provider: "google")

      expect(GoogleCalendarAPIMock, :list_calendars, fn _client ->
        {:ok, [%{"id" => "primary", "summary" => "Primary", "primary" => true}]}
      end)

      assert {:ok, calendars} = Discovery.discover_calendars_for_integration(integration)
      assert length(calendars) == 1
      assert Enum.at(calendars, 0).name == "Primary"
    end

    test "discovers for outlook provider" do
      integration = insert(:calendar_integration, provider: "outlook")

      expect(OutlookCalendarAPIMock, :list_calendars, fn _client ->
        {:ok, [%{"id" => "cal1", "name" => "Outlook", "isDefaultCalendar" => true}]}
      end)

      assert {:ok, calendars} = Discovery.discover_calendars_for_integration(integration)
      assert length(calendars) == 1
      assert Enum.at(calendars, 0).name == "Outlook"
    end

    test "handles unknown provider" do
      assert {:error, "Unknown provider: unknown"} =
               Discovery.discover_calendars_for_integration(%{provider: "unknown"})
    end

    test "discovers for baikal provider via decrypt chain" do
      # Exercises the full credential-decrypt → resolve_provider_atom →
      # provider_module_for → Baikal.Provider.new → Baikal.Provider.discover_calendars
      # chain, which was previously uncovered by mock-based tests.
      integration =
        insert(:calendar_integration,
          provider: "baikal",
          base_url: "https://baikal.example.com/dav.php",
          username_encrypted: Encryption.encrypt("testuser"),
          password_encrypted: Encryption.encrypt("testpass")
        )

      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 207,
           body: """
           <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
             <D:response>
               <D:href>/dav.php/calendars/testuser/default/</D:href>
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
         }}
      end)

      assert {:ok, calendars} = Discovery.discover_calendars_for_integration(integration)
      assert Enum.map(calendars, & &1.name) == ["Personal"]
    end
  end

  describe "discover_calendars_for_credentials/5" do
    test "returns error for unknown provider" do
      assert {:error, "Unknown provider: unknown"} =
               Discovery.discover_calendars_for_credentials(
                 :unknown,
                 "http://url",
                 "u",
                 "p"
               )
    end

    test "returns error for invalid provider string" do
      assert {:error, "Unknown provider: invalid"} =
               Discovery.discover_calendars_for_credentials(
                 "invalid",
                 "http://url",
                 "u",
                 "p"
               )
    end
  end

  describe "maybe_discover_calendars/1" do
    test "passes through non-caldav providers" do
      attrs = %{provider: "google"}
      assert {:ok, ^attrs} = Discovery.maybe_discover_calendars(attrs)
    end

    test "handles caldav provider with no paths found" do
      # Invalid URL causes discovery to fail silently — returns attrs unchanged.
      attrs = %{provider: "caldav", base_url: "http://invalid"}
      assert {:ok, ^attrs} = Discovery.maybe_discover_calendars(attrs)
    end

    test "dispatches nextcloud through CalDAV discovery" do
      # Invalid URL causes discovery to fail silently — returns attrs unchanged.
      attrs = %{provider: "nextcloud", base_url: "http://invalid"}
      assert {:ok, ^attrs} = Discovery.maybe_discover_calendars(attrs)
    end
  end
end
