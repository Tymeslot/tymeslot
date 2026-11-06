defmodule Tymeslot.Contacts.CardDAVTest do
  use Tymeslot.HttpTransportCase, async: false

  @moduletag :integrations

  alias Tymeslot.Contacts.CardDAV
  alias Tymeslot.Test.CardDAVStub

  @client %{
    base_url: "https://dav.example.com/remote.php/dav",
    username: "ada",
    password: "secret",
    provider: :nextcloud
  }

  @books %{
    "/addressbooks/user/contacts/" => [
      {"Grace Hopper", ["grace@example.com"]},
      {"Alan Turing", ["alan@example.com", "turing@work.example"]}
    ],
    "/addressbooks/user/work/" => [{nil, ["ops@example.com"]}]
  }

  describe "address_books/1" do
    test "follows the principal to its address book home and lists the books in it" do
      CardDAVStub.stub("ada:secret", @books)

      assert {:ok, hrefs} = CardDAV.address_books(@client)
      assert Enum.sort(hrefs) == ["/addressbooks/user/contacts/", "/addressbooks/user/work/"]
    end

    test "says so when the server keeps no address books" do
      CardDAVStub.stub("ada:secret", %{})

      assert {:error, :no_address_books} = CardDAV.address_books(@client)
    end

    test "passes a refused login through" do
      CardDAVStub.stub("someone:else", @books)

      assert {:error, :unauthorized} = CardDAV.address_books(@client)
    end
  end

  describe "search/3" do
    test "returns one entry per address of the cards matching the term" do
      CardDAVStub.stub("ada:secret", @books)

      assert {:ok, contacts} = CardDAV.search(@client, "/addressbooks/user/contacts/", "TUR")

      assert contacts == [
               %{name: "Alan Turing", email: "alan@example.com"},
               %{name: "Alan Turing", email: "turing@work.example"}
             ]
    end

    test "asks for names and addresses only, with the term escaped" do
      CardDAVStub.stub("ada:secret", @books)

      assert {:ok, []} = CardDAV.search(@client, "/addressbooks/user/contacts/", "<a&b>")

      assert_received {:carddav_request, "REPORT", "/addressbooks/user/contacts/", body}
      assert body =~ ~s(<card:prop name="FN"/>)
      assert body =~ ~s(<card:prop name="EMAIL"/>)
      assert body =~ "&lt;a&amp;b&gt;"
      refute body =~ "<a&b>"
    end
  end
end
