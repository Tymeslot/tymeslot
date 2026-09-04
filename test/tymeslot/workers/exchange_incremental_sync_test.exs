defmodule Tymeslot.Workers.ExchangeIncrementalSyncTest do
  @moduledoc """
  Covers the incremental half of the Exchange item read: the `SyncFolderItems`
  change feed, the per-folder tokens it is driven by, and the daily full re-read
  that backstops it.

  Split from `SyncExchangeCalendarWorkerTest`, which is about keeping the two
  halves of the cache apart. This one is about a different risk. The full read
  is self-healing — it replaces a role's rows wholesale, so a missed change
  costs one cycle — and the incremental read is not: a deletion the feed fails
  to state is a row that stays on the grid, and a token stored after a failed
  run acknowledges changes nobody applied. Every test here is one of those
  ways for the cache and the mailbox to drift apart in silence.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.ExchangeSyncStubs
  import Tymeslot.Factory

  @moduletag :workers
  @moduletag :calendar
  @moduletag :integrations

  alias Ecto.Changeset
  alias Tymeslot.ExchangeCase
  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  @base_url "https://mail.example.com/EWS/Exchange.asmx"

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    ExchangeCase.reset_breaker(@base_url)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        base_url: @base_url,
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        provider_account_email: "user@example.com",
        calendar_list: []
      )

    %{user: user, integration: integration}
  end

  test "the first run reads the window and stores a token for each folder", %{
    integration: integration
  } do
    stub_full_sync()

    assert :ok = run(integration)

    # Without the bootstrap every run would be a full one, and the change
    # feed would never be used at all.
    assert %{exchange_sync_states: %{"calendar" => token}} = Repo.reload!(integration)
    assert token == ExchangeFixtures.sync_state()
  end

  test "a later run asks the feed instead of re-reading the window", %{
    integration: integration
  } do
    stub_full_sync()
    assert :ok = run(integration)
    # Drain the first run's requests; what is asserted below is what the
    # *second* run sent.
    sent_requests()

    stub_full_sync()
    assert :ok = run(integration)

    requests = sent_requests()

    # The whole point of the mechanism: an unchanged folder costs one cheap
    # `IdOnly` round trip rather than a `FindItem` and a `GetItem`.
    assert Enum.any?(requests, &(&1 =~ "<m:SyncFolderItems"))
    refute Enum.any?(requests, &(&1 =~ "<m:FindItem"))
  end

  test "a run whose feed reports nothing leaves the cached rows alone", %{
    integration: integration
  } do
    stub_full_sync()
    assert :ok = run(integration)
    before = grid_rows(integration)
    assert [_row] = before

    stub_full_sync()
    assert :ok = run(integration)

    # A no-op run must not be a wipe: nothing is replaced on this path, so
    # the rows the full read wrote have to survive untouched.
    assert Enum.map(grid_rows(integration), & &1.uid) == Enum.map(before, & &1.uid)
  end

  test "a deletion the feed states removes the cached row", %{integration: integration} do
    stub_full_sync()
    assert :ok = run(integration)
    assert [row] = grid_rows(integration)

    stub_full_sync(
      sync_folder_items:
        ExchangeFixtures.sync_folder_items_response([{:delete, row.provider_event_id}],
          sync_state: "sync-state-2"
        )
    )

    assert :ok = run(integration)

    # The incremental path has no replacement set, so a deletion is only ever
    # visible because the server stated it. If this row survived, a meeting
    # cancelled in Outlook would stay on the grid until the next full read.
    assert grid_rows(integration) == []
    assert %{exchange_sync_states: %{"calendar" => "sync-state-2"}} = Repo.reload!(integration)
  end

  test "an item the feed reports as changed is refetched and upserted", %{
    integration: integration
  } do
    stub_full_sync()
    assert :ok = run(integration)
    assert [row] = grid_rows(integration)
    assert row.summary == "Standup"

    stub_full_sync(
      sync_folder_items:
        ExchangeFixtures.sync_folder_items_response([{:update, row.provider_event_id}],
          sync_state: "sync-state-2"
        ),
      get_item: ExchangeFixtures.get_item_response(subject: "Standup, renamed")
    )

    assert :ok = run(integration)

    assert [updated] = grid_rows(integration)
    assert updated.summary == "Standup, renamed"
  end

  test "a changed item whose dates leave the sync window is dropped from the cache", %{
    integration: integration
  } do
    stub_full_sync()
    assert :ok = run(integration)
    assert [row] = grid_rows(integration)

    far_future = DateTime.add(DateTime.utc_now(), 400, :day)

    stub_full_sync(
      sync_folder_items:
        ExchangeFixtures.sync_folder_items_response([{:update, row.provider_event_id}],
          sync_state: "sync-state-2"
        ),
      get_item:
        ExchangeFixtures.get_item_response(
          start: DateTime.to_iso8601(far_future),
          end: DateTime.to_iso8601(DateTime.add(far_future, 3600, :second))
        )
    )

    assert :ok = run(integration)

    # The feed cannot say whether an item was removed or merely moved, and a
    # cached row for an item outside the window is one the grid would render
    # in the wrong place. Caching it because the sync mentioned it would be
    # the bug.
    assert grid_rows(integration) == []
  end

  test "a feed that cannot be read fails the run rather than reporting no changes", %{
    integration: integration
  } do
    stub_full_sync()
    assert :ok = run(integration)

    stub_full_sync(
      sync_folder_items: ExchangeFixtures.failed_response("SyncFolderItems", "ErrorAccessDenied")
    )

    # Reading a refusal as an empty change set would freeze the cache: every
    # later cycle would ask the same question, be refused the same way, and
    # report the same nothing.
    assert {:error, {:response_code, "ErrorAccessDenied"}} = run(integration)
    assert [_row] = grid_rows(integration)
  end

  test "a failed run does not advance the stored token", %{integration: integration} do
    stub_full_sync()
    assert :ok = run(integration)
    assert %{exchange_sync_states: %{"calendar" => first_token}} = Repo.reload!(integration)

    stub_full_sync(
      sync_folder_items: ExchangeFixtures.failed_response("SyncFolderItems", "ErrorAccessDenied")
    )

    assert {:error, _reason} = run(integration)

    # An advanced token after a failed run would acknowledge changes that
    # were never applied, and nothing would ever report them again.
    assert %{exchange_sync_states: %{"calendar" => ^first_token}} = Repo.reload!(integration)
  end

  test "a token the server refuses is dropped and the folder re-bootstraps", %{
    integration: integration
  } do
    stub_full_sync()
    assert :ok = run(integration)
    assert %{exchange_sync_states: %{"calendar" => _token}} = Repo.reload!(integration)
    sent_requests()

    stub_full_sync(
      sync_folder_items:
        ExchangeFixtures.failed_response("SyncFolderItems", "ErrorInvalidSyncStateData")
    )

    # Keeping a token the server has refused strands the folder for good: the
    # same token is replayed every cycle, refused identically, and the run
    # fails while still paying for the whole availability read.
    assert :ok = run(integration)

    assert Enum.any?(sent_requests(), &(&1 =~ "<m:FindItem"))
    assert Repo.reload!(integration).exchange_sync_states == %{}
    assert is_nil(Repo.reload!(integration).sync_error)
  end

  test "the folder that lost its token bootstraps a fresh one next cycle", %{
    integration: integration
  } do
    stub_full_sync()
    assert :ok = run(integration)

    stub_full_sync(
      sync_folder_items:
        ExchangeFixtures.failed_response("SyncFolderItems", "ErrorInvalidSyncStateVersion")
    )

    assert :ok = run(integration)

    stub_full_sync(sync_folder_items: ExchangeFixtures.sync_folder_items_response([]))
    assert :ok = run(integration)

    # Without this the recovery is only half of one: the folder would take a
    # full read every cycle from here on, having never got a token back.
    assert %{exchange_sync_states: %{"calendar" => token}} = Repo.reload!(integration)
    assert token == ExchangeFixtures.sync_state()
  end

  test "a booking the feed reports is cached as one of ours", %{integration: integration} do
    stub_full_sync()
    assert :ok = run(integration)

    # Booked after the full read, so the incremental path is the only one that
    # can flag the mirror row. Left unflagged, everything keyed on
    # `created_by_tymeslot` treats a confirmed booking as somebody else's
    # event until the daily full read happens to rewrite it.
    insert(:meeting, calendar_integration_id: integration.id, provider_event_id: "item-2")

    stub_full_sync(
      sync_folder_items:
        ExchangeFixtures.sync_folder_items_response([{:create, "item-2"}],
          sync_state: "sync-state-2"
        ),
      get_item: ExchangeFixtures.get_item_response(id: "item-2", uid: "uid-2")
    )

    assert :ok = run(integration)

    rows = Map.new(grid_rows(integration), &{&1.provider_event_id, &1})

    assert %{created_by_tymeslot: true} = rows["item-2"]
    # And only that one: flagging is a claim of ownership, not a blanket mark
    # on whatever the feed happened to mention.
    assert %{created_by_tymeslot: false} = rows["item-1"]
  end

  test "a stale full sync forces the window to be re-read", %{integration: integration} do
    stub_full_sync()
    assert :ok = run(integration)

    sent_requests()

    age_last_full_sync(integration)
    stub_full_sync()

    assert :ok = run(integration)

    # The window slides daily, so an item can enter it without changing and
    # therefore without appearing in any feed. Only the full read finds those.
    assert Enum.any?(sent_requests(), &(&1 =~ "<m:FindItem"))
  end

  test "an incremental cycle does not push the full re-read out of reach", %{
    integration: integration
  } do
    # `last_full_sync_at` is the clock the daily full re-read is measured
    # against. Stamping it on every successful cycle kept it permanently
    # fresh, so the re-read never came due again and items sliding into the
    # window were never picked up.
    stub_full_sync()
    assert :ok = run(integration)

    # Recent enough that no full read is due, so the next cycle is genuinely
    # incremental, and distinctive enough that overwriting it is visible.
    stamped = DateTime.add(DateTime.utc_now(:second), -1, :hour)

    integration
    |> Changeset.change(%{last_full_sync_at: stamped})
    |> Repo.update!()

    sent_requests()

    stub_full_sync()
    assert :ok = run(integration)

    # No windowed read this cycle, and the full-read clock is untouched.
    refute Enum.any?(sent_requests(), &(&1 =~ "<m:FindItem"))
    assert Repo.reload!(integration).last_full_sync_at == stamped
  end

  test "a full re-read does move the clock it is measured against", %{
    integration: integration
  } do
    stub_full_sync()
    assert :ok = run(integration)

    aged = age_last_full_sync(integration)
    stub_full_sync()
    assert :ok = run(integration)

    assert DateTime.compare(
             Repo.reload!(integration).last_full_sync_at,
             aged.last_full_sync_at
           ) == :gt
  end

  test "an incremental cycle still records that the integration synced", %{
    integration: integration
  } do
    # Holding `last_full_sync_at` back must not make an incremental cycle look
    # like a failure: the sweep schedules Exchange off `last_external_sync_at`,
    # and the health row is cleared on every successful run.
    stub_full_sync()
    assert :ok = run(integration)

    stale = DateTime.add(DateTime.utc_now(:second), -1, :hour)

    integration
    |> Changeset.change(%{last_external_sync_at: stale, last_sync_at: stale})
    |> Repo.update!()

    stub_full_sync()
    assert :ok = run(integration)

    reloaded = Repo.reload!(integration)
    assert DateTime.compare(reloaded.last_external_sync_at, stale) == :gt
    assert DateTime.compare(reloaded.last_sync_at, stale) == :gt
    assert is_nil(reloaded.sync_error)
  end
end
