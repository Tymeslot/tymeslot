defmodule Tymeslot.Integrations.Calendar.Exchange.CreationTest do
  @moduledoc """
  Covers connecting an Exchange mailbox from the connection form.

  The invariant worth pinning here is the one that makes an Exchange
  integration *different from every other one the form creates*: it addresses
  a mailbox rather than a folder, so it carries a `provider_account_email` the
  CalDAV attrs have no place for.

  Its folders were forced `read_only: true` while the provider refused every
  write; that override is gone now the write path exists, and the two tests
  below pin what replaced it.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Exchange.Creation, as: ExchangeCreation
  alias Tymeslot.Profiles.ProfileQueries

  @moduletag :integrations
  @moduletag :calendar

  setup :verify_on_exit!

  @folder_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgBAAEAAAA="

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Work Exchange",
        "provider" => "exchange",
        "url" => "https://mail.example.com/EWS/Exchange.asmx",
        "username" => "EXAMPLE\\alice",
        "password" => "secret",
        "mailbox" => "alice@example.com",
        "verify_ssl" => "true",
        "calendar_list" => [
          %CalendarEntry{id: @folder_id, name: "Calendar", type: "calendar"}
        ]
      },
      overrides
    )
  end

  # The connection probe runs a live `FindFolder` before the row is written.
  defp stub_probe(status \\ 200) do
    body = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
      <s:Body>
        <m:FindFolderResponse>
          <m:ResponseMessages>
            <m:FindFolderResponseMessage ResponseClass="Success">
              <m:ResponseCode>NoError</m:ResponseCode>
            </m:FindFolderResponseMessage>
          </m:ResponseMessages>
        </m:FindFolderResponse>
      </s:Body>
    </s:Envelope>
    """

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: status, body: body}}
    end)
  end

  describe "create_with_validation/3" do
    setup do
      user = insert(:user)
      insert(:profile, user: user)
      %{user: user}
    end

    test "persists the mailbox address the availability read is addressed to", %{user: user} do
      stub_probe()

      assert {:ok, integration} = ExchangeCreation.create_with_validation(user.id, params())

      # Not the username: the login here is a domain login, which
      # `GetUserAvailability` cannot address.
      assert integration.provider_account_email == "alice@example.com"
      assert integration.provider == "exchange"
      assert integration.base_url == "https://mail.example.com/EWS/Exchange.asmx"
    end

    test "leaves every discovered folder writable", %{user: user} do
      stub_probe()

      assert {:ok, integration} = ExchangeCreation.create_with_validation(user.id, params())

      assert [%CalendarEntry{} = entry] = integration.calendar_list
      assert entry.id == @folder_id
      assert entry.selected
      # `read_only` means "the server says this cannot be written". `FindFolder`
      # says nothing about rights, so nothing here may claim it does, and the
      # write path means there is no longer a reason to force the flag on
      # anyway. A folder left writable is one the booking pickers will offer.
      refute entry.read_only
    end

    test "becomes the user's primary calendar when it is their first", %{user: user} do
      stub_probe()

      assert {:ok, integration} = ExchangeCreation.create_with_validation(user.id, params())

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)

      # The inverse of what this pinned while the provider was read-only. An
      # Exchange mailbox now accepts a booking write, so promoting it to
      # primary leaves the user with a primary that works, and refusing to
      # would leave someone whose only calendar is Exchange with none.
      assert profile.primary_calendar_integration_id == integration.id
    end

    test "stores verify_ssl false when the form's box is unticked", %{user: user} do
      stub_probe()

      assert {:ok, integration} =
               ExchangeCreation.create_with_validation(
                 user.id,
                 params(%{"verify_ssl" => "false"})
               )

      refute integration.verify_ssl
    end

    test "defaults verify_ssl to false when the key is absent entirely", %{user: user} do
      stub_probe()

      # An unticked HTML checkbox submits nothing at all.
      assert {:ok, integration} =
               ExchangeCreation.create_with_validation(
                 user.id,
                 Map.delete(params(), "verify_ssl")
               )

      refute integration.verify_ssl
    end

    test "stores verify_ssl true when the box is left ticked", %{user: user} do
      stub_probe()

      assert {:ok, integration} = ExchangeCreation.create_with_validation(user.id, params())

      assert integration.verify_ssl
    end

    test "refuses a second integration for the same endpoint and login", %{user: user} do
      stub_probe()

      assert {:ok, _first} = ExchangeCreation.create_with_validation(user.id, params())

      assert {:error, :duplicate_integration} =
               ExchangeCreation.create_with_validation(user.id, params())
    end

    test "reports a rejected credential on the form rather than writing a row", %{user: user} do
      stub_probe(401)

      assert {:error, {:form_errors, errors}} =
               ExchangeCreation.create_with_validation(user.id, params())

      # The probe's own sentence, not a field-level complaint: a rejected
      # credential is never attributable to one input.
      assert errors[:discovery] =~ ~r/credential|password|username|authenticat/i
      assert Repo.aggregate(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, :count) == 0
    end

    test "refuses a mailbox that is not an address", %{user: user} do
      assert {:error, {:form_errors, errors}} =
               ExchangeCreation.create_with_validation(user.id, params(%{"mailbox" => "alice"}))

      assert errors[:mailbox] == "Enter a mailbox address in the form name@example.com"
      assert Repo.aggregate(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, :count) == 0
    end

    test "accepts a mailbox in an internal-only domain", %{user: user} do
      stub_probe()

      # An on-premises Exchange routinely addresses mailboxes in a domain that
      # is not a public TLD. Validating this field against the public TLD list
      # would refuse exactly the deployments this provider exists for.
      assert {:ok, integration} =
               ExchangeCreation.create_with_validation(
                 user.id,
                 params(%{"mailbox" => "alice@mail.corp.internal"})
               )

      assert integration.provider_account_email == "alice@mail.corp.internal"
    end

    test "enqueues the first sync so the mailbox is not silently free until the sweep", %{
      user: user
    } do
      stub_probe()

      assert {:ok, integration} = ExchangeCreation.create_with_validation(user.id, params())

      assert_enqueued(
        worker: Tymeslot.Workers.SyncExchangeCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end
end
