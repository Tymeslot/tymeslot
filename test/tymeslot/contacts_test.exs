defmodule Tymeslot.ContactsTest do
  @moduledoc """
  Contact suggestions across a host's calendar connections: which take part,
  how their contacts are merged and ranked, and that a server that cannot be
  read contributes nothing rather than failing the search.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Contacts
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.CardDAVStub

  @books %{
    "/addressbooks/user/contacts/" => [
      {"Grace Hopper", ["grace@example.com"]},
      {"Ada Lovelace", ["ada@example.com"]},
      {"Adrian Mole", ["mole@example.com"]}
    ],
    "/addressbooks/user/shared/" => [{"Ada (shared)", ["ada@example.com"]}]
  }

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    user = insert(:user)
    %{user: user}
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

  test "finds contacts by name or address, best first, one entry per address", %{user: user} do
    connection(user)
    CardDAVStub.stub("ada:secret", @books)

    assert Contacts.search(user.id, "ad") == [
             %{name: "Ada Lovelace", email: "ada@example.com"},
             %{name: "Adrian Mole", email: "mole@example.com"}
           ]
  end

  test "finds nothing for a term too short to search with", %{user: user} do
    connection(user)
    CardDAVStub.stub("ada:secret", @books)

    assert Contacts.search(user.id, "a") == []
    refute_received {:carddav_request, _method, _path, _body}
  end

  test "asks no server when no connection takes part", %{user: user} do
    connection(user, use_for_contacts: false)
    connection(user, provider: "google", use_for_contacts: true)
    CardDAVStub.stub("ada:secret", @books)

    refute Contacts.enabled?(user.id)
    assert Contacts.search(user.id, "ada") == []
    refute_received {:carddav_request, _method, _path, _body}
  end

  test "a server that refuses the login contributes nothing", %{user: user} do
    connection(user)
    CardDAVStub.stub("someone:else", @books)

    assert Contacts.search(user.id, "ada") == []
  end

  test "only the owner's connections are searched", %{user: user} do
    connection(insert(:user))
    CardDAVStub.stub("ada:secret", @books)

    assert Contacts.search(user.id, "ada") == []
  end

  describe "turning suggestions on and off" do
    test "is offered on a connection that keeps address books", %{user: user} do
      integration = connection(user, use_for_contacts: false)

      assert {:ok, %{use_for_contacts: true}} =
               Calendar.set_use_for_contacts(user.id, integration.id, true)

      assert Contacts.enabled?(user.id)
    end

    test "is refused on one that does not, and on another host's", %{user: user} do
      google = connection(user, provider: "google", use_for_contacts: false)
      foreign = connection(insert(:user), use_for_contacts: false)

      assert {:error, :contacts_not_supported} =
               Calendar.set_use_for_contacts(user.id, google.id, true)

      assert {:error, _not_found} = Calendar.set_use_for_contacts(user.id, foreign.id, true)
    end
  end
end
