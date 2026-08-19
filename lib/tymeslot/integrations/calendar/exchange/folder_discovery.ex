defmodule Tymeslot.Integrations.Calendar.Exchange.FolderDiscovery do
  @moduledoc """
  Turns a `FindFolder` response into `CalendarEntry` structs.

  A `Deep` traversal from `msgfolderroot` returns every folder in the mailbox,
  so calendars are picked out by element name (`t:CalendarFolder`) rather than
  by guessing from the display name. Every property except the folder id is
  treated as optional, for the reason `Exchange.EventNormaliser` documents: a
  live server drops properties it does not implement rather than faulting, so
  a missing element carries no signal about the request.

  ## A failed response message fails the call

  `Requests.find_folder/0` names one parent folder and so gets one response
  message back. Skipping a message that did not succeed would answer
  `{:ok, []}` for a mailbox that could not be enumerated at all, which the
  caller cannot tell apart from a mailbox holding no calendars and would
  persist as an emptied calendar list. The response code is surfaced instead,
  so the failure stays visible and callers can map it (`ErrorAccessDenied`
  and `ErrorNonExistentMailbox` being the ones an operator actually hits).

  ## Entries are not flagged read-only

  `read_only: true` means "the server says this calendar cannot be written".
  `FindFolder` with the `Default` folder shape reports no rights at all, so
  setting the flag would be asserting something the server never stated. That
  this phase writes nothing is a property of the provider, not of the folder,
  and is enforced where the write path is offered rather than here.
  """

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  require Logger

  @type error_reason :: {:response_code, String.t()} | :no_response_messages

  # A FindFolder response carries no marker for the mailbox's default
  # calendar: `DistinguishedFolderId` is a request-only element, and the
  # Default folder shape returns nothing else that singles one out. Short of a
  # second round trip (a `GetFolder` on `DistinguishedFolderId Id="calendar"`,
  # whose folder id could then be matched against these), the display name is
  # the only signal, and Exchange localises it: a German mailbox names its
  # default calendar "Kalender". A mailbox holding exactly one calendar folder
  # therefore needs no name match at all, since the default calendar cannot be
  # deleted and so must be that folder. Anything else leaves no primary, which
  # callers already treat as "unknown" rather than as a confirmed negative.
  @primary_display_name "Calendar"

  @doc """
  Extracts every calendar folder from a parsed `FindFolder` response.
  """
  @spec parse_calendars(Soap.document()) ::
          {:ok, [CalendarEntry.t()]} | {:error, error_reason()}
  def parse_calendars(doc) do
    case Soap.response_messages(doc, "FindFolderResponseMessage") do
      [] -> {:error, :no_response_messages}
      messages -> parse_messages(messages)
    end
  end

  defp parse_messages(messages) do
    case Enum.find(messages, &(Soap.response_code(&1) != "NoError")) do
      nil -> {:ok, messages |> Enum.flat_map(&calendar_folders/1) |> to_entries()}
      failed -> {:error, {:response_code, Soap.response_code(failed)}}
    end
  end

  defp calendar_folders(message) do
    Soap.xpath(message, ~x"./m:RootFolder/t:Folders/t:CalendarFolder"l)
  end

  defp to_entries(folders) do
    {usable, dropped} =
      folders
      |> Enum.map(&to_entry/1)
      |> Enum.split_with(&identified?/1)

    log_dropped(dropped)
    mark_primary(usable)
  end

  # A folder id is what makes an entry usable: it is how the folder is named
  # back to the server and how a user's selection is stored. An entry without
  # one would occupy a row in the calendar list that can never sync.
  defp identified?(%CalendarEntry{id: nil}), do: false
  defp identified?(%CalendarEntry{}), do: true

  # A calendar missing from the picker is as invisible to its owner as a
  # meeting missing from the diary, so dropping one is stated rather than left
  # silent. Only the count travels: a folder's display name is mailbox
  # content. No operator alert accompanies it, unlike the one
  # `Exchange.EventNormaliser` raises for a dropped item: discovery carries no
  # `calendar_integration_id` to name in an alert, and every alert type
  # describes an event rather than a folder.
  defp log_dropped([]), do: :ok

  defp log_dropped(dropped) do
    Logger.warning("Skipping Exchange calendar folders carrying no folder id",
      provider: :exchange,
      count: length(dropped)
    )
  end

  defp to_entry(folder) do
    %CalendarEntry{
      id: Soap.text(folder, ~x"./t:FolderId/@Id"),
      name: Soap.text(folder, ~x"./t:DisplayName/text()"),
      type: "calendar",
      selected: false,
      read_only: false,
      primary: false
    }
  end

  # At most one entry is ever marked, so a mailbox with a subfolder that
  # happens to share the default calendar's name still reports one primary.
  defp mark_primary(entries) do
    case Enum.find_index(entries, &(&1.name == @primary_display_name)) do
      nil -> mark_sole_calendar(entries)
      index -> List.update_at(entries, index, &%{&1 | primary: true})
    end
  end

  defp mark_sole_calendar([entry]), do: [%{entry | primary: true}]
  defp mark_sole_calendar(entries), do: entries
end
