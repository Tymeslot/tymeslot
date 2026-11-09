defmodule Tymeslot.Workers.ContactsSyncWorkerTest do
  @moduledoc """
  The contact sync jobs: one connection's sync, and the sweep queueing one
  for every connection that suggests contacts.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Contacts
  alias Tymeslot.Contacts.{AddressBookSchema, ContactQueries}
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.CardDAVStub
  alias Tymeslot.Workers.{ContactsSyncSweepWorker, ContactsSyncWorker}

  @books %{"/addressbooks/user/contacts/" => [{"Grace Hopper", ["grace@example.com"]}]}

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    CardDAVStub.stub("ada:secret", @books)
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

  defp run_sync(integration),
    do: perform_job(ContactsSyncWorker, %{"calendar_integration_id" => integration.id})

  test "syncs the connection's address books", %{user: user} do
    integration = connection(user)

    assert :ok = run_sync(integration)
    assert [%{name: "Grace Hopper"}] = Contacts.search(user.id, "grace")
  end

  test "deletes what was synced for a connection that stopped suggesting contacts", %{
    user: user
  } do
    integration = connection(user)
    :ok = run_sync(integration)

    integration |> Ecto.Changeset.change(use_for_contacts: false) |> Repo.update!()

    assert :ok = run_sync(integration)
    assert ContactQueries.list_books(integration.id) == []
  end

  test "lets an unreachable server wait for the next sweep", %{user: user} do
    integration = connection(user)
    CardDAVStub.stub("someone:else", @books)

    assert :ok = run_sync(integration)
  end

  test "discards a job for a connection that is gone" do
    assert {:discard, _reason} =
             perform_job(ContactsSyncWorker, %{"calendar_integration_id" => -1})
  end

  describe "the sweep" do
    test "queues a sync for every connection that suggests contacts", %{user: user} do
      taking_part = connection(user)
      _off = connection(user, use_for_contacts: false)
      _google = connection(user, provider: "google")

      assert :ok = perform_job(ContactsSyncSweepWorker, %{})

      assert [%{args: %{"calendar_integration_id" => id}}] =
               all_enqueued(worker: ContactsSyncWorker)

      assert id == taking_part.id
    end

    test "deletes what is left synced for connections that stopped suggesting contacts", %{
      user: user
    } do
      integration = connection(user)
      :ok = run_sync(integration)
      integration |> Ecto.Changeset.change(use_for_contacts: false) |> Repo.update!()

      assert :ok = perform_job(ContactsSyncSweepWorker, %{})
      assert Repo.aggregate(AddressBookSchema, :count) == 0
    end
  end
end
