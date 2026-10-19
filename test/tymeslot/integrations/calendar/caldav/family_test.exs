defmodule Tymeslot.Integrations.Calendar.CalDAV.FamilyTest do
  # Every registry that lists the CalDAV family must agree with the table, row
  # by row, so a member added to one and forgotten in another fails here.
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.Family
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  test "the family is exactly ProviderConfig's CalDAV family" do
    assert Family.members() ==
             [:caldav, :radicale, :nextcloud, :zimbra, :mailbox_org, :apple, :baikal]

    assert ProviderConfig.caldav_based_providers() == Family.members()
  end

  # Literal on purpose: an expectation read from the table would move with
  # any mistake made in it. Generic CalDAV detects its server type instead.
  @client_providers %{
    caldav: :caldav,
    radicale: :radicale,
    nextcloud: :nextcloud,
    zimbra: :zimbra,
    mailbox_org: :mailbox_org,
    apple: :apple,
    baikal: :baikal
  }

  for member <- Family.members() do
    @member member

    describe "#{member}" do
      test "is named alike by the table, ProviderConfig and its provider module" do
        assert module = ProviderConfig.get_provider_module(@member)
        assert ProviderConfig.display_name(@member) == Family.display_name(@member)
        assert module.display_name() == Family.display_name(@member)
      end

      test "locks the server address the table fixes, and only that one" do
        expected = Family.row!(@member).fixed_url

        assert ProviderConfig.locked_url_for(@member) == expected
        assert ProviderConfig.locked_url_for(Atom.to_string(@member)) == expected
      end

      test "builds a client from a stored row that names its own provider" do
        client =
          CaldavCommon.client_for_integration(%{
            provider: Atom.to_string(@member),
            # A host the server detector does not recognise, so generic
            # CalDAV falls back to `:caldav` rather than a detected type.
            base_url: "https://dav.example.com",
            username: "user",
            password: "pass",
            calendar_paths: []
          })

        assert client.provider == Map.fetch!(@client_providers, @member)
      end
    end
  end

  test "locks exactly the iCloud and mailbox.org addresses" do
    assert Map.new(Family.fixed_urls(), fn {member, %{url: url}} -> {member, url} end) == %{
             apple: "https://caldav.icloud.com",
             mailbox_org: "https://dav.mailbox.org"
           }
  end
end
