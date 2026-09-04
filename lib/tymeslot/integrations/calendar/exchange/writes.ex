defmodule Tymeslot.Integrations.Calendar.Exchange.Writes do
  @moduledoc """
  The EWS write operations: `CreateItem`, `UpdateItem` and `DeleteItem`.

  `Exchange.Provider`'s three write callbacks are thin wrappers around these,
  and `Calendar.Diagnostics` reaches them directly to plant and remove the
  fixtures `mix calendar_audit` reads back. Both callers want the same three
  operations against the same transport, so they share one implementation
  rather than the audit keeping a private copy of it.

  ## The item id is the handle, not the UID

  EWS assigns a calendar item's iCalendar `UID` itself; a `t:UID` sent on
  `CreateItem` is ignored, verified against a live server. What comes back is
  an item id, which is also what `Exchange.EventNormaliser` writes into
  `provider_event_id`. Callers therefore address an item they created by item
  id, never by a uid they chose, and `Meetings.CalendarEventSync` persists
  exactly that id when it reads the `%{id: item_id}` a create answers.

  ## Two response codes mean "gone"

  A live server answers `ErrorItemNotFound` for an item that existed and no
  longer does, and `ErrorInvalidId` for an id it cannot even deserialise. Both
  are reported here as `:not_found`, because the caller's move is the same for
  either: `CalendarEventSync` recreates the event and repoints the meeting at
  the new id. Reporting an unreadable id as anything else would leave a meeting
  permanently unable to sync, retrying a write against a handle no server will
  ever accept.

  ## Errors keep the server's own words otherwise

  Every other stated failure travels as `{:response_code, code}`, the shape
  `Exchange.Soap` produces and the sync worker already words for the account
  owner. Nothing here invents a second vocabulary for a refusal EWS already
  named.
  """

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Integrations.Calendar.Exchange.Client
  alias Tymeslot.Integrations.Calendar.Exchange.Requests
  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Integrations.Calendar.Reminder

  @typedoc "The handle an item is addressed by after it is written."
  @type item_id :: String.t()

  @typedoc """
  The item a write describes. `Exchange.Requests.item_spec/0` owns the shape,
  including what an absent key means against a key carrying `nil`.
  """
  @type spec :: Requests.item_spec()

  # EWS states a refusal in a 200 response body, so these are response codes
  # rather than statuses. Both mean the id names nothing writable; see the
  # moduledoc for why they collapse to one atom.
  @gone_codes ~w(ErrorItemNotFound ErrorInvalidId ErrorInvalidIdMalformed)

  @doc """
  Creates one calendar item and returns the id the server assigned it.

  `folder` is `:calendar` for the mailbox's default calendar, or an EWS folder
  id.
  """
  @spec create_item(Client.config(), spec(), :calendar | String.t()) ::
          {:ok, item_id()} | {:error, term()}
  def create_item(config, spec, folder \\ :calendar) when is_map(spec) do
    with {:ok, doc} <- Client.call(config, Requests.create_item(spec, folder)),
         {:ok, messages} <- require_success(doc, "CreateItemResponseMessage") do
      created_id(messages)
    end
  end

  @doc """
  Rewrites the fields of an existing item.

  Answers `:ok` rather than the item's new id: the id survives an update
  unchanged, verified against a live server, so a caller already holds it.
  """
  @spec update_item(Client.config(), item_id(), spec()) :: :ok | {:error, term()}
  def update_item(config, item_id, spec) when is_binary(item_id) and is_map(spec) do
    with {:ok, doc} <- Client.call(config, Requests.update_item(item_id, spec)),
         {:ok, _messages} <- require_success(doc, "UpdateItemResponseMessage") do
      :ok
    end
  end

  @doc """
  Removes one item.

  `{:error, :not_found}` when the item is already gone. That is not softened
  to `:ok` here: whether a missing item counts as a successful deletion is the
  caller's call, and `Meetings.CalendarEventSync` already treats it as one.
  """
  @spec delete_item(Client.config(), item_id()) :: :ok | {:error, term()}
  def delete_item(config, item_id) when is_binary(item_id) do
    with {:ok, doc} <- Client.call(config, Requests.delete_item(item_id)),
         {:ok, _messages} <- require_success(doc, "DeleteItemResponseMessage") do
      :ok
    end
  end

  @doc """
  Maps the canonical event data a booking carries into an `item_spec`.

  `Tymeslot.Integrations.Calendar.CalendarEventBuilder` builds one map for
  every provider; this is Exchange's reading of it.

  Four of its keys are deliberately dropped. `uid` cannot be honoured at all:
  EWS assigns its own and ignores the one sent. `organizer_name`,
  `organizer_email`, `attendee_name` and `attendee_email` are not turned into
  EWS attendees, because attendees would make the item a meeting and have the
  server send its own invitation on top of the one Tymeslot already sent; they
  reach the organiser's diary inside `description`, which the builder assembles
  with them in it. `attachments` has no place on a `t:CalendarItem` body and
  would need a separate `CreateAttachment` round trip. `timezone` is the
  attendee's, and the bounds are absolute instants, so it changes nothing about
  when the item sits.

  Every key the spec can carry is emitted, including the ones whose value is
  `nil`. That is what makes an update clear a field the meeting no longer has,
  rather than leave last week's location on a rescheduled booking; see
  `Exchange.Requests.item_spec/0`.
  """
  @spec from_event_data(map()) :: spec()
  def from_event_data(event_data) when is_map(event_data) do
    %{
      summary: event_data[:summary],
      description: event_data[:description],
      start_time: event_data[:start_time],
      end_time: event_data[:end_time],
      location: event_data[:location],
      transparency: event_data[:transparency] || :opaque,
      reminder_minutes: reminder_minutes(event_data[:reminders])
    }
  end

  # EWS carries one reminder per item, as a lead time in minutes, so only the
  # first survives. Outlook's Graph mapping loses the rest the same way, and
  # `Tymeslot.Integrations.Calendar.Reminder` documents the limit.
  defp reminder_minutes(reminders) do
    reminders
    |> List.wrap()
    |> Enum.find_value(&Reminder.minutes_before/1)
  end

  defp require_success(doc, message_name) do
    case Soap.require_success(doc, message_name) do
      {:ok, messages} -> {:ok, messages}
      {:error, {:response_code, code}} when code in @gone_codes -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # A success message carrying no id is not a success this caller can use: the
  # item is on the server and nothing can address it to update or remove it.
  # Saying so beats answering `{:ok, nil}` and failing at the next write.
  defp created_id(messages) do
    case Enum.find_value(messages, &id_in/1) do
      nil -> {:error, :no_item_id}
      id -> {:ok, id}
    end
  end

  defp id_in(message) do
    Soap.text(message, ~x"./m:Items/t:CalendarItem/t:ItemId/@Id")
  end
end
