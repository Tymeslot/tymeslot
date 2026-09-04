defmodule Tymeslot.Integrations.Calendar.Exchange.DiscoveryTest do
  @moduledoc """
  Covers discovering an Exchange mailbox's folders through the shared
  discovery funnel the connection form calls.

  Two things here are Exchange's alone and fail silently if they regress. The
  funnel drops any calendar the sync could not later address, and it decides
  that on `path` — which an EWS folder does not have, since it is named by the
  opaque `FolderId` the server issues. `CalendarEntry.with_defaults/1` copies
  that id across, and if it stopped doing so the funnel would answer
  `{:ok, []}` and the form would render a mailbox holding no calendars. And
  `verify_ssl` has to reach the transport, because discovery runs before the
  integration whose column would otherwise carry it exists.
  """

  # async: false so `Mox.set_mox_from_context/1` puts the mock in global mode:
  # the discovery chain runs its HTTP call inside a circuit-breaker process,
  # which holds no Mox allowance of its own.
  use Tymeslot.DataCase, async: false

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Shared.DiscoveryCache

  @moduletag :integrations
  @moduletag :calendar

  setup :verify_on_exit!

  setup do
    DiscoveryCache.clear_all()
    :ok
  end

  @folder_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgBAAEAAAA="

  @find_folder_response """
  <?xml version="1.0" encoding="utf-8"?>
  <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
              xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"
              xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
    <s:Body>
      <m:FindFolderResponse>
        <m:ResponseMessages>
          <m:FindFolderResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode>
            <m:RootFolder>
              <t:Folders>
                <t:CalendarFolder>
                  <t:FolderId Id="#{@folder_id}" ChangeKey="ck1"/>
                  <t:DisplayName>Calendar</t:DisplayName>
                </t:CalendarFolder>
              </t:Folders>
            </m:RootFolder>
          </m:FindFolderResponseMessage>
        </m:ResponseMessages>
      </m:FindFolderResponse>
    </s:Body>
  </s:Envelope>
  """

  defp discover(user, opts) do
    Calendar.discover_and_filter_calendars(
      :exchange,
      "https://mail.example.com/EWS/Exchange.asmx",
      "alice@example.com",
      "secret",
      user.id,
      opts
    )
  end

  describe "discover_and_filter_calendars/6 for Exchange" do
    setup do
      user = insert(:user)
      insert(:profile, user: user)
      %{user: user}
    end

    test "keeps a folder the funnel can still address", %{user: user} do
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: @find_folder_response}}
      end)

      assert {:ok, %{calendars: calendars}} = discover(user, [])

      # The whole point: a folder that survives the funnel's `path` filter,
      # which it only does because `with_defaults/1` carries the FolderId over.
      # Were it dropped, the form would say "no calendars were discovered".
      assert [folder] = calendars
      assert folder.id == @folder_id
      assert folder.name == "Calendar"
      assert folder.path == @folder_id
    end

    test "passes verify_ssl false through to the transport", %{user: user} do
      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, opts ->
        send(test_pid, {:transport_opts, opts})
        {:ok, %Req.Response{status: 200, body: @find_folder_response}}
      end)

      assert {:ok, _result} = discover(user, verify_ssl: false)

      assert_received {:transport_opts, opts}

      # An on-premises server behind a self-signed certificate is refused
      # outright if the setting does not reach the connect options here.
      connect_options = Keyword.get(opts, :connect_options, [])
      transport_opts = Keyword.get(connect_options, :transport_opts, [])
      assert Keyword.get(transport_opts, :verify) == :verify_none
    end

    test "verifies the certificate when the caller says nothing", %{user: user} do
      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, opts ->
        send(test_pid, {:transport_opts, opts})
        {:ok, %Req.Response{status: 200, body: @find_folder_response}}
      end)

      assert {:ok, _result} = discover(user, [])

      assert_received {:transport_opts, opts}

      connect_options = Keyword.get(opts, :connect_options, [])
      transport_opts = Keyword.get(connect_options, :transport_opts, [])
      refute Keyword.get(transport_opts, :verify) == :verify_none
    end
  end
end
