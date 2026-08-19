defmodule Tymeslot.Integrations.Calendar.Exchange.Requests do
  @moduledoc """
  Builders for the EWS request bodies this provider issues.

  Each function returns the operation element only; wrapping it in a SOAP
  envelope is `Exchange.Soap.envelope/1`'s job.

  ## Why the read path is two calls

  `FindItem` cannot return an item's iCalendar `UID`: the property is silently
  dropped from `AdditionalProperties` rather than faulted, which was confirmed
  against a live server. `CalendarEvent` requires a stable non-empty `uid`, so
  `FindItem` is used purely to enumerate item ids over a `CalendarView`, and a
  single batched `GetItem` fetches the fields. `GetItem` accepts many ids and
  answers one response message per id, so the cost is two round trips per sync
  window regardless of how many events fall in it.

  `IncludeMimeContent` is deliberately never requested. It returns a base64
  MIME multipart message whose `text/calendar` part is quoted-printable
  encoded, so reaching the iCalendar inside costs a MIME parse and a QP decode
  to obtain fields that `BaseShape=Default` already returns as typed XML.

  ## Paging is not implemented

  Neither builder requests an indexed page view, so `FindItem` returns at most
  the server's `FindCountLimit` worth of items and truncates the rest. Nothing
  reads `IncludesLastItemInRange` either, so a folder or sync window larger
  than that limit is silently short rather than an error: the response carries
  `IncludesLastItemInRange="false"` and the events past the cut simply never
  reach the caller. Paging is deliberately left out of this phase; adding it
  means an `m:IndexedPageItemView` on `find_item/3` and a loop driven by that
  attribute.
  """

  @doc "Enumerates the mailbox's folders so calendars can be picked out."
  @spec find_folder() :: String.t()
  def find_folder do
    """
    <m:FindFolder Traversal="Deep">
      <m:FolderShape><t:BaseShape>Default</t:BaseShape></m:FolderShape>
      <m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderIds>
    </m:FindFolder>
    """
  end

  @doc """
  Enumerates item ids in a calendar folder over a time range.

  `folder` is either `:calendar` (the mailbox's default calendar) or an EWS
  folder id string.
  """
  @spec find_item(:calendar | String.t(), DateTime.t(), DateTime.t()) :: String.t()
  def find_item(folder, %DateTime{} = from, %DateTime{} = to)
      when folder == :calendar or is_binary(folder) do
    """
    <m:FindItem Traversal="Shallow">
      <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape>
      <m:CalendarView StartDate="#{calendar_view_time(from)}" EndDate="#{calendar_view_time(to)}"/>
      <m:ParentFolderIds>#{folder_element(folder)}</m:ParentFolderIds>
    </m:FindItem>
    """
  end

  @doc """
  Fetches the given items in one request.

  Takes `{item_id, change_key}` pairs as returned by `FindItem`, and requires
  at least one. An empty batch is a caller bug rather than a degenerate case
  to render: `m:ItemIds` demands a child, so the server would answer a schema
  fault to a request that could only ever have returned nothing. Callers skip
  the operation when the window is empty, and the guard makes forgetting that
  fail here rather than a round trip later.
  """
  @spec get_item([{String.t(), String.t()}, ...]) :: String.t()
  def get_item([_pair | _rest] = ids) do
    item_ids =
      Enum.map_join(ids, "\n", fn {id, change_key} ->
        ~s(<t:ItemId Id="#{escape(id)}" ChangeKey="#{escape(change_key)}"/>)
      end)

    """
    <m:GetItem>
      <m:ItemShape><t:BaseShape>Default</t:BaseShape></m:ItemShape>
      <m:ItemIds>#{item_ids}</m:ItemIds>
    </m:GetItem>
    """
  end

  defp folder_element(:calendar), do: ~s(<t:DistinguishedFolderId Id="calendar"/>)
  defp folder_element(id) when is_binary(id), do: ~s(<t:FolderId Id="#{escape(id)}"/>)

  # EWS ids are base64 and so cannot contain XML metacharacters, but they reach
  # this module from the server and from the database rather than from a
  # constant, so they are escaped rather than trusted to be well-formed.
  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # The shift normalises the caller's zone away: `CalendarView` bounds are
  # absolute instants, and a zoned bound would otherwise be rendered with its
  # own offset. Shifting to `Etc/UTC` needs no timezone database, and
  # `DateTime.to_iso8601/1` renders a UTC datetime with a `Z` suffix, so no
  # offset rewriting is needed afterwards.
  defp calendar_view_time(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
