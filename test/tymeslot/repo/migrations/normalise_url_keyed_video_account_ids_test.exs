defmodule Tymeslot.Repo.Migrations.NormaliseUrlKeyedVideoAccountIdsTest do
  @moduledoc """
  MiroTalk, Jitsi and custom video link integrations saved before keys were
  normalised hold the address as typed, or the address they had before an
  edit. The backfill rewrites each key to the normalised form of the current
  address, except where an active row would then share its key with another
  active row of the same owner and provider, which the unique index refuses.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :video
  @moduletag :migrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.AccountKey
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_917_172_100

  setup do
    %{user: insert(:user)}
  end

  test "rewrites a key typed with a trailing slash and a capitalised host", %{user: user} do
    row = integration(user, "mirotalk", "HTTPS://P2P.Example.com/")

    MigrationRunner.replay!(@version)

    assert key(row) == "https://p2p.example.com"
  end

  test "moves a key an edit left on the old address to the current one", %{user: user} do
    row =
      integration(user, "jitsi", "https://new.example.com:443/", key: "https://old.example.com")

    MigrationRunner.replay!(@version)

    assert key(row) == "https://new.example.com"
  end

  test "keys a custom link on its address with the query string and path case kept",
       %{user: user} do
    row = integration(user, "custom", "https://Zoom.us/j/Abc/?pwd=XyZ")

    MigrationRunner.replay!(@version)

    assert key(row) == "https://zoom.us/j/Abc?pwd=XyZ"
  end

  test "produces the key new writes use", %{user: user} do
    urls = [
      "HTTPS://A.example.com:443/",
      "http://b.example.com:80//",
      "https://c.example.com:8443/Room/?pwd=Q",
      " https://d.example.com/ "
    ]

    rows = Enum.map(urls, &integration(user, "custom", &1))

    MigrationRunner.replay!(@version)

    assert Enum.map(rows, &key/1) == Enum.map(urls, &AccountKey.from_url/1)
  end

  test "leaves an active row alone when another active row already holds its key",
       %{user: user} do
    held = integration(user, "mirotalk", "https://dup.example.com")
    duplicate = integration(user, "mirotalk", "https://DUP.example.com/")

    MigrationRunner.replay!(@version)

    assert key(held) == "https://dup.example.com"
    assert key(duplicate) == "https://DUP.example.com/"
  end

  test "rewrites only one of two active rows that normalise to the same key", %{user: user} do
    first = integration(user, "jitsi", "https://Twice.example.com/")
    second = integration(user, "jitsi", "https://twice.example.com//")

    MigrationRunner.replay!(@version)

    assert key(first) == "https://twice.example.com"
    assert key(second) == "https://twice.example.com//"
  end

  test "rewrites an inactive or disconnected row even onto an active row's key",
       %{user: user} do
    integration(user, "mirotalk", "https://shared.example.com")
    inactive = integration(user, "mirotalk", "https://Shared.example.com/", is_active: false)

    disconnected =
      integration(user, "mirotalk", "https://SHARED.example.com",
        is_active: false,
        deleted_at: DateTime.utc_now(:second)
      )

    MigrationRunner.replay!(@version)

    assert key(inactive) == "https://shared.example.com"
    assert key(disconnected) == "https://shared.example.com"
  end

  test "counts a row whose active state was never set as inactive", %{user: user} do
    integration(user, "jitsi", "https://unset.example.com")
    unset = integration(user, "jitsi", "https://Unset.example.com/")

    # The schema default fills in a nil, so only raw SQL can leave it unset, as
    # a row written outside the application could.
    Repo.query!("UPDATE video_integrations SET is_active = NULL WHERE id = $1", [unset.id])

    MigrationRunner.replay!(@version)

    assert key(unset) == "https://unset.example.com"
  end

  test "rewrites a row onto a key another row gives up in the same backfill", %{user: user} do
    moving_on =
      integration(user, "custom", "https://z.example.com/c", key: "https://y.example.com/b")

    moving_up =
      integration(user, "custom", "https://y.example.com/b/", key: "https://x.example.com/a")

    MigrationRunner.replay!(@version)

    assert key(moving_on) == "https://z.example.com/c"
    assert key(moving_up) == "https://y.example.com/b"
  end

  test "treats each owner separately", %{user: user} do
    integration(user, "mirotalk", "https://p2p.example.com")
    other = integration(insert(:user), "mirotalk", "https://P2P.example.com/")

    MigrationRunner.replay!(@version)

    assert key(other) == "https://p2p.example.com"
  end

  test "leaves other providers and rows without an address alone", %{user: user} do
    talk =
      integration(user, "nextcloud_talk", "https://Cloud.example.com/",
        key: "https://Cloud.example.com/||organiser"
      )

    no_address = integration(user, "jitsi", nil, key: "https://Legacy.example.com/")

    MigrationRunner.replay!(@version)

    assert key(talk) == "https://Cloud.example.com/||organiser"
    assert key(no_address) == "https://Legacy.example.com/"
  end

  test "changes nothing when run a second time", %{user: user} do
    rows = [
      integration(user, "mirotalk", "https://again.example.com"),
      integration(user, "mirotalk", "https://AGAIN.example.com/"),
      integration(user, "custom", "https://Link.example.com/")
    ]

    MigrationRunner.replay!(@version)
    keys = Enum.map(rows, &key/1)
    MigrationRunner.replay!(@version)

    assert Enum.map(rows, &key/1) == keys
  end

  # A row as an earlier release saved it: keyed on the address as typed unless
  # `:key` says otherwise.
  defp integration(user, provider, url, overrides \\ []) do
    url_field = if provider == "custom", do: :custom_meeting_url, else: :base_url

    insert(
      :video_integration,
      [
        {:user, user},
        {:provider, provider},
        {url_field, url},
        {:provider_account_id, Keyword.get(overrides, :key, url)}
        | Keyword.delete(overrides, :key)
      ]
    )
  end

  defp key(row), do: Repo.get!(VideoIntegrationSchema, row.id).provider_account_id
end
