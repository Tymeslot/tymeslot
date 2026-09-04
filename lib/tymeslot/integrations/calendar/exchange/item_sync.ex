defmodule Tymeslot.Integrations.Calendar.Exchange.ItemSync do
  @moduledoc """
  Turns a `SyncFolderItems` response into the changes since the last token.

  This is the incremental half of the item read. `Exchange.ItemDiscovery` still
  owns the windowed enumeration `FindItem` answers; this module owns the
  folder's change feed, which is a different question with a different shape.

  ## The feed is folder-wide, not window-wide

  `SyncFolderItems` takes no `CalendarView` and answers for the whole folder,
  so a change to an item ten years out arrives exactly like a change to one
  next week. Bounding the result to the sync window is the caller's job, and it
  can only be done after the fields are fetched, because the ids this module
  answers carry no dates. `Tymeslot.Workers.SyncExchangeCalendarWorker` does
  that filtering; nothing here knows the window exists.

  ## A first call enumerates everything

  With no token the server reports every item in the folder as a `Create`. That
  is the intended bootstrap, and it is also what a token the server cannot read
  degrades to: a live server answered `NoError` to arbitrary bytes and
  re-enumerated the folder rather than refusing. The failure direction is
  therefore a redundant full read, never a silent "nothing changed", which is
  why the caller may store and replay a token without validating it.

  ## Deletions are stated, not inferred

  A `t:Delete` change carries a bare `t:ItemId` and no item body at all, so a
  deletion is known by id alone. This is the one thing the windowed read cannot
  answer: `FindItem` reports what *is* there, and a caller reconciles by
  replacing the lot. An incremental caller has no replacement set, so it
  depends on these ids being complete for the span the token covers.

  ## `IncludesLastItemInRange` bounds one response, not the sync

  `MaxChangesReturned` caps a single response. `false` means the server has
  more to say and the caller must call again with the new token before the feed
  is caught up. A caller that ignores it processes a prefix of the changes and
  then stores a token that says it saw them all, which strands the rest until
  something forces a full re-read.
  """

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Integrations.Calendar.Exchange.Client
  alias Tymeslot.Integrations.Calendar.Exchange.ItemDiscovery
  alias Tymeslot.Integrations.Calendar.Exchange.Requests
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  @typedoc """
  One batch of changes.

  `created` and `updated` carry `{item_id, change_key}` pairs, ready for a
  batched `GetItem`; the two are kept apart because a caller may want to know
  which is which, even though both need the same fetch. `deleted` carries item
  ids alone, which is all a `t:Delete` states.

  `last?` is the response's `IncludesLastItemInRange`, and `sync_state` the
  token to send next. A response stating no token yields `nil`, which a caller
  must treat as "do not advance": storing `nil` would restart the feed from
  scratch next cycle.
  """
  @type changes :: %{
          sync_state: String.t() | nil,
          last?: boolean(),
          created: [ItemDiscovery.id_pair()],
          updated: [ItemDiscovery.id_pair()],
          deleted: [String.t()]
        }

  # One response's worth of changes. Large enough that an ordinary cycle is a
  # single round trip, small enough that the first call against a long-lived
  # mailbox does not ask for its entire history at once.
  @max_changes_returned 512

  # Bounds the drain loop. A server that keeps answering
  # `IncludesLastItemInRange=false` without ever advancing its token would
  # otherwise spin forever inside one Oban job. Five hundred pages at the cap
  # above is a quarter of a million changes, far past any real folder, so
  # reaching this is a broken server rather than a busy one.
  @max_pages 500

  # The two response codes EWS uses to refuse a token rather than the request.
  # `ErrorInvalidSyncStateData` is a token the server cannot read at all;
  # `ErrorInvalidSyncStateVersion` is one it could read but issued under a
  # schema it no longer honours. Both say the same thing to a caller — this
  # token is spent — and neither is fixed by sending it again.
  @invalid_sync_state_codes ["ErrorInvalidSyncStateData", "ErrorInvalidSyncStateVersion"]

  @doc """
  Tells whether a failure means the *token* is unusable rather than the request.

  The distinction matters because the two failures need opposite handling. An
  `ErrorAccessDenied` says nothing about the stored token, so keeping it is
  right: the folder is unreadable this cycle and readable again when the
  rights come back. A refused token is the other way round — every later cycle
  replays the same spent token, is refused identically, and the folder never
  syncs again — so a caller must drop it and re-bootstrap from a full read.

  Deliberately narrow. Only these two codes name the token itself; anything
  else, including a code this provider has never seen, keeps the token, because
  discarding one on an unrecognised failure trades a permanent stall for a
  whole-folder re-enumeration every cycle.
  """
  @spec invalid_sync_state?(term()) :: boolean()
  def invalid_sync_state?({:response_code, code}), do: code in @invalid_sync_state_codes
  def invalid_sync_state?(_other), do: false

  @doc """
  Drains a folder's change feed and answers everything since `sync_state`.

  A **live** EWS read, and the incremental counterpart to
  `Exchange.Provider.list_calendar_items/2`. It owns its own transport for the
  same reason `Exchange.Writes` does: the operation, its paging rule and its
  response shape are one subject, and splitting the loop from the parser would
  put half of `IncludesLastItemInRange`'s meaning in another module.

  `sync_state` is `nil` for a folder never synced this way, which enumerates
  it in full.

  ## Paging is drained here, not by the caller

  A response is capped at `#{@max_changes_returned}` changes, and one stating
  `IncludesLastItemInRange=false` has more behind it. This drains until the
  server says it is caught up, then answers the accumulated changes under the
  final token. A caller storing that token has genuinely seen everything it
  claims to, which is the property the whole mechanism rests on.

  A failure part-way through is the whole read's failure, and the token is not
  advanced: the changes already collected are dropped rather than persisted
  under a token that would then skip the rest of the feed.
  """
  @spec fetch_changes(Client.config(), :calendar | String.t(), String.t() | nil) ::
          {:ok, changes()} | {:error, term()}
  def fetch_changes(config, folder, sync_state) do
    drain(config, folder, sync_state, empty_changes(), @max_pages)
  end

  defp drain(_config, _folder, _sync_state, _acc, 0), do: {:error, :sync_paging_exhausted}

  defp drain(config, folder, sync_state, acc, pages_left) do
    body = Requests.sync_folder_items(folder, sync_state, @max_changes_returned)

    with {:ok, doc} <- Client.call(config, body),
         {:ok, page} <- parse_changes(doc) do
      merged = concat(acc, page)

      # A page that states no token cannot be paged past: sending `nil` again
      # would restart the feed and loop on the same changes forever. Stopping
      # here answers what was read under a nil token, and a caller that must
      # not advance on a nil token then falls back to a full read.
      if page.last? or is_nil(page.sync_state) do
        {:ok, merged}
      else
        drain(config, folder, page.sync_state, merged, pages_left - 1)
      end
    end
  end

  defp concat(acc, page) do
    %{
      sync_state: page.sync_state || acc.sync_state,
      last?: page.last?,
      created: acc.created ++ page.created,
      updated: acc.updated ++ page.updated,
      deleted: acc.deleted ++ page.deleted
    }
  end

  @doc """
  Reads the changes a parsed `SyncFolderItems` response carries.

  The response code is checked before anything is read from the body, for the
  reason `Exchange.ItemDiscovery` documents: a failed message carries no
  `m:Changes`, so walking straight to them answers "no changes" for a folder
  that could not be read at all, and an incremental caller persists that as a
  folder where nothing happened.
  """
  @spec parse_changes(Soap.document()) :: {:ok, changes()} | {:error, Soap.failure()}
  def parse_changes(doc) do
    with {:ok, messages} <- Soap.require_success(doc, "SyncFolderItemsResponseMessage") do
      {:ok, Enum.reduce(messages, empty_changes(), &merge_message/2)}
    end
  end

  defp empty_changes do
    %{sync_state: nil, last?: true, created: [], updated: [], deleted: []}
  end

  # A response carries one message per request, so the reduce folds a list of
  # one in practice. It still folds rather than taking the head, because a
  # server answering more than one must not have the rest silently dropped:
  # the changes concatenate, and the token and the last-in-range flag come
  # from the final message, which is the one describing where the feed now
  # stands.
  defp merge_message(message, acc) do
    %{
      sync_state: Soap.text(message, ~x"./m:SyncState/text()") || acc.sync_state,
      last?: Soap.text(message, ~x"./m:IncludesLastItemInRange/text()") != "false",
      created: acc.created ++ id_pairs(message, "Create"),
      updated: acc.updated ++ id_pairs(message, "Update"),
      deleted: acc.deleted ++ deleted_ids(message)
    }
  end

  # A `Create` or `Update` wraps the item, so the id sits one level deeper than
  # in a `Delete`. `t:CalendarItem` rather than a wildcard: a calendar folder
  # can hold a `t:MeetingRequest` or a plain `t:Item`, and neither is something
  # the grid can render, so they drop out of the walk structurally.
  defp id_pairs(message, change) do
    message
    |> Soap.xpath(~x"./m:Changes/t:#{change}/t:CalendarItem/t:ItemId"l)
    |> Enum.map(&to_id_pair/1)
    |> Enum.reject(&is_nil/1)
  end

  # A deletion states an id and nothing else, not even a change key: the
  # version that was deleted is not a thing a caller can act on.
  defp deleted_ids(message) do
    message
    |> Soap.xpath(~x"./m:Changes/t:Delete/t:ItemId"l)
    |> Enum.map(&Soap.text(&1, ~x"./@Id"))
    |> Enum.reject(&is_nil/1)
  end

  # An id is what makes an item fetchable, so one without it is dropped rather
  # than sent. The change key is optional to EWS and this provider sends none
  # of its own on a write, so `""` stands in exactly as it does on the
  # windowed read.
  defp to_id_pair(item_id) do
    case Soap.text(item_id, ~x"./@Id") do
      nil -> nil
      id -> {id, Soap.text(item_id, ~x"./@ChangeKey") || ""}
    end
  end
end
