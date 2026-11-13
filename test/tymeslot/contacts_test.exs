defmodule Tymeslot.ContactsTest do
  @moduledoc """
  Contact suggestions across a host's calendar connections: syncing their
  address books into Tymeslot, searching what was synced, and removing it
  again when suggestions are turned off.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Contacts
  alias Tymeslot.Contacts.{AddressBookSchema, ContactQueries, ContactSchema, Sync}
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.CardDAVStub
  alias Tymeslot.Workers.ContactsSyncWorker

  @books %{
    "/addressbooks/user/contacts/" => [
      {"Grace Hopper", ["grace@example.com"]},
      {"Ada Lovelace", ["ada@example.com"]},
      {"Adrian Mole", ["mole@example.com"]},
      {"Miller, Claudia", ["claudia.m@example.com"]},
      {"No Address", []},
      {"Broken", ["not an address"]}
    ],
    "/addressbooks/user/shared/" => [{"Ada (shared)", ["ADA@example.com"]}]
  }

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    %{user: insert(:user)}
  end

  defp connection(user, attrs \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          user: user,
          provider: "nextcloud",
          base_url: "https://dav.example.com/remote.php/dav",
          username_encrypted: Encryption.encrypt("ada"),
          password_encrypted: Encryption.encrypt("secret"),
          use_for_contacts: true
        ],
        attrs
      )
    )
  end

  defp sync(integration) do
    {:ok, integration} = CalendarIntegrationQueries.get(integration.id)
    Sync.run(integration)
  end

  defp flush_requests do
    receive do
      {:carddav_request, _method, _path, _body} -> flush_requests()
    after
      0 -> :ok
    end
  end

  describe "syncing" do
    test "stores every address of every book, without placeholders", %{user: user} do
      integration = connection(user)
      CardDAVStub.stub("ada:secret", @books)

      assert {:ok, %{synced: 2, unchanged: 0, failed: 0}} = sync(integration)

      emails = Repo.all(from(c in ContactSchema, select: c.email))

      assert Enum.sort(emails) == [
               "ada@example.com",
               "ada@example.com",
               "claudia.m@example.com",
               "grace@example.com",
               "mole@example.com"
             ]
    end

    test "keeps names and addresses encrypted at rest", %{user: user} do
      integration = connection(user)
      CardDAVStub.stub("ada:secret", @books)
      {:ok, _outcome} = sync(integration)

      %{rows: rows} = Repo.query!("SELECT name_encrypted, email_encrypted FROM calendar_contacts")

      for [name, email] <- rows, value <- [name, email], is_binary(value) do
        refute value =~ "example.com"
        refute value =~ "Grace"
      end
    end

    test "lists a book again only once its token changes", %{user: user} do
      integration = connection(user)
      books = %{"/addressbooks/user/contacts/" => [{"Grace Hopper", ["grace@example.com"]}]}

      CardDAVStub.stub("ada:secret", books, tokens: %{"/addressbooks/user/contacts/" => "1"})
      assert {:ok, %{synced: 1}} = sync(integration)
      flush_requests()

      assert {:ok, %{synced: 0, unchanged: 1}} = sync(integration)
      refute_received {:carddav_request, "REPORT", _path, _body}

      changed = %{"/addressbooks/user/contacts/" => [{"Grace B. Hopper", ["grace@example.com"]}]}
      CardDAVStub.stub("ada:secret", changed, tokens: %{"/addressbooks/user/contacts/" => "2"})

      assert {:ok, %{synced: 1}} = sync(integration)
      assert [%{name: "Grace B. Hopper"}] = Contacts.search(user.id, "grace")
    end

    test "drops a book that is gone from the server", %{user: user} do
      integration = connection(user)
      CardDAVStub.stub("ada:secret", @books)
      {:ok, _outcome} = sync(integration)

      CardDAVStub.stub("ada:secret", Map.delete(@books, "/addressbooks/user/contacts/"))
      {:ok, _outcome} = sync(integration)

      assert [%{href: "/addressbooks/user/shared/"}] = ContactQueries.list_books(integration.id)
      assert Contacts.search(user.id, "grace") == []
    end

    test "keeps what a book had when it cannot be listed this time", %{user: user} do
      integration = connection(user)
      CardDAVStub.stub("ada:secret", @books)
      {:ok, _outcome} = sync(integration)

      CardDAVStub.stub("ada:secret", Map.put(@books, "/addressbooks/user/contacts/", :refuse))

      assert {:ok, %{failed: 1}} = sync(integration)
      assert [%{name: "Grace Hopper"}] = Contacts.search(user.id, "grace")
    end

    test "passes on a server that refuses the login", %{user: user} do
      integration = connection(user)
      CardDAVStub.stub("someone:else", @books)

      assert {:error, :unauthorized} = sync(integration)
    end

    test "finds the books of a Nextcloud connection stored with the bare server address",
         %{user: user} do
      integration = connection(user, base_url: "https://dav.example.com")

      CardDAVStub.stub(
        "ada:secret",
        %{
          "/remote.php/dav/addressbooks/users/ada/contacts/" => [
            {"Grace Hopper", ["grace@example.com"]}
          ]
        },
        dav_root: "/remote.php/dav",
        principal: "/remote.php/dav/principals/users/ada/",
        home: "/remote.php/dav/addressbooks/users/ada/"
      )

      assert {:ok, %{synced: 1}} = sync(integration)
    end
  end

  describe "searching" do
    setup %{user: user} do
      integration = connection(user)
      CardDAVStub.stub("ada:secret", @books)
      {:ok, _outcome} = sync(integration)
      %{integration: integration}
    end

    test "finds contacts by any part of the name or address, best first, one per address",
         %{user: user} do
      assert Contacts.search(user.id, "ad") == [
               %{name: "Ada Lovelace", email: "ada@example.com"},
               %{name: "Adrian Mole", email: "mole@example.com"}
             ]

      assert Contacts.search(user.id, "claudia") == [
               %{name: "Miller, Claudia", email: "claudia.m@example.com"}
             ]

      assert [%{name: "Grace Hopper"}] = Contacts.search(user.id, "OPPER")
    end

    test "asks no server", %{user: user} do
      flush_requests()

      assert [_grace] = Contacts.search(user.id, "grace")
      refute_received {:carddav_request, _method, _path, _body}
    end

    test "finds nothing for a term too short to search with", %{user: user} do
      assert Contacts.search(user.id, "a") == []
    end

    test "leaves out a connection that stopped suggesting contacts", %{
      user: user,
      integration: integration
    } do
      integration |> Changeset.change(use_for_contacts: false) |> Repo.update!()

      assert Contacts.search(user.id, "grace") == []
    end

    test "searches only the owner's contacts" do
      assert Contacts.search(insert(:user).id, "grace") == []
    end
  end

  describe "turning suggestions on and off" do
    test "syncs right away when turned on", %{user: user} do
      integration = connection(user, use_for_contacts: false)

      assert {:ok, %{use_for_contacts: true}} =
               Calendar.set_use_for_contacts(user.id, integration.id, true)

      assert_enqueued(
        worker: ContactsSyncWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "deletes what was synced when turned off", %{user: user} do
      integration = connection(user)
      CardDAVStub.stub("ada:secret", @books)
      {:ok, _outcome} = sync(integration)

      assert {:ok, %{use_for_contacts: false}} =
               Calendar.set_use_for_contacts(user.id, integration.id, false)

      assert Repo.aggregate(AddressBookSchema, :count) == 0
      assert Repo.aggregate(ContactSchema, :count) == 0
    end

    test "takes what was synced along when the calendar is disconnected", %{user: user} do
      integration = connection(user)
      CardDAVStub.stub("ada:secret", @books)
      {:ok, _outcome} = sync(integration)

      Repo.delete!(integration)

      assert Repo.aggregate(ContactSchema, :count) == 0
    end

    test "is refused on a connection without address books, and on another host's", %{
      user: user
    } do
      google = connection(user, provider: "google", use_for_contacts: false)
      foreign = connection(insert(:user), use_for_contacts: false)

      assert {:error, :contacts_not_supported} =
               Calendar.set_use_for_contacts(user.id, google.id, true)

      assert {:error, _not_found} = Calendar.set_use_for_contacts(user.id, foreign.id, true)
    end
  end
end
