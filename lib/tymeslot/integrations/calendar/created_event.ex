defmodule Tymeslot.Integrations.Calendar.CreatedEvent do
  @moduledoc """
  What a provider answers a successful create with.

  A create is the one moment Tymeslot holds a new event's server-side identity
  for free: the resource the provider just wrote, and, on CalDAV, the entity
  tag the server assigned it. The contract used to be a bare `any()`, a uid
  string for the CalDAV family and a converted event map for the OAuth
  providers, with nowhere to put either. So the grid cached the row with
  `provider_event_id` and `etag` NULL and left the next full sync to repair
  them, and everything that reads those columns (the conditional update's
  precondition, the colour write-back, the calendar a write is routed to) was
  degraded until it did.

  Fields:

    * `:uid`: the event's **iCalendar UID**, and only ever that. The CalDAV
      family is written the uid the caller generated and answers with it, so
      it is known there from the create onwards. `nil` for the providers that
      mint an identifier of their own and never report an iCalendar UID; those
      answer through `:provider_event_id` instead.
    * `:provider_event_id`: the provider's own handle on the resource, and what
      the cached grid row's column of the same name holds. A server-root-
      relative CalDAV href, or a Google, Outlook or Exchange event id. `nil`
      when the provider's answer does not carry one.
    * `:calendar_id`: the collection the event was actually written to, as the
      cached row's `provider_calendar_id` spells it. The caller's request is
      not the answer: a CalDAV write falls back to the booking collection when
      the requested calendar is not one the integration lists as writable, and
      caching the request rather than the outcome files the row under a
      calendar the event is not on, which is where the next edit then looks for
      it. `nil` when the provider does not report one.
    * `:etag`: the entity tag the server assigned, stored the way sync stores
      one, with its surrounding quotes stripped (`EventProcessor.clean_etag/1`)
      so the same tag compares equal however a server spells it. `nil`
      whenever the server did not return one: RFC 4791 only says a server
      SHOULD answer a PUT with an ETag, and a server that rewrote the
      submitted document must not. A missing tag is an ordinary create, never
      a failed one.
    * `:raw`: the provider's own answer, untouched, for the callers that read
      provider-specific fields out of it (the inline Google Meet URL above
      all). `nil` for providers that answer with nothing but an identifier.

  Keeping `:uid` strictly iCalendar is what lets a caller tell the two kinds of
  identifier apart without knowing which provider it is talking to.
  `Meetings.CalendarEventSync` needs exactly that: a meeting is keyed by its
  iCalendar UID, and writing a provider-minted id into that column would key it
  by a value no sync ever produces. Callers that simply need "whatever this
  event is known by here" ask for `local_uid/1`.

  Deliberately does not carry the created document: `raw_ical` on a cached row
  means "the server's copy", and echoing back what Tymeslot submitted would
  make the colour write-back patch a snapshot that never existed, silently
  reverting whatever the server normalised or added. That column stays NULL
  until a read fills it.
  """

  defstruct [:uid, :provider_event_id, :calendar_id, :etag, :raw]

  @type t :: %__MODULE__{
          uid: String.t() | nil,
          provider_event_id: String.t() | nil,
          calendar_id: String.t() | nil,
          etag: String.t() | nil,
          raw: map() | nil
        }

  @doc """
  Builds a result for a provider that answers with the iCalendar UID it was given.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(uid, opts \\ []) when is_binary(uid) do
    %__MODULE__{
      uid: uid,
      provider_event_id: Keyword.get(opts, :provider_event_id),
      calendar_id: Keyword.get(opts, :calendar_id),
      etag: Keyword.get(opts, :etag),
      raw: Keyword.get(opts, :raw)
    }
  end

  @doc """
  Builds a result for a provider that mints its own identifier.

  Answers with `:uid` unset, because none of these providers reports an
  iCalendar UID on create: Google and Outlook carry one on the response but
  under a key Tymeslot does not yet read, and EWS ignores a `t:UID` sent on
  create outright.
  """
  @spec provider_minted(String.t(), keyword()) :: t()
  def provider_minted(id, opts \\ []) when is_binary(id) do
    %__MODULE__{
      uid: nil,
      provider_event_id: id,
      etag: Keyword.get(opts, :etag),
      raw: Keyword.get(opts, :raw)
    }
  end

  @doc """
  Builds a result from a provider's own event representation.

  Used by the OAuth providers, which answer a create with the event they made.
  `:raw` keeps that response for the caller that needs a conference link out of
  it. A response naming the event in no way at all yields a result with both
  identifiers unset rather than an error, since the event was nonetheless
  created.
  """
  @spec from_provider_event(map()) :: t()
  def from_provider_event(%{} = event) do
    case identifier(event) do
      nil -> %__MODULE__{raw: event}
      id -> provider_minted(id, raw: event)
    end
  end

  @doc """
  The identifier this event is cached and addressed under locally.

  The iCalendar UID when the provider deals in one, otherwise the id it
  minted, which is the only thing it will answer to. `nil` only when the
  provider named the event in no way at all.
  """
  @spec local_uid(t()) :: String.t() | nil
  def local_uid(%__MODULE__{uid: uid}) when is_binary(uid), do: uid
  def local_uid(%__MODULE__{provider_event_id: id}), do: id

  # Providers spell their identifier either as the `:id` of a raw response or
  # as the `:uid` of a converted one, in string- or atom-keyed form depending
  # on how far the response has been normalised. Where both appear, `id` is the
  # unambiguous one: `uid` on a converted OAuth event is that same provider id
  # under a name that elsewhere means an iCalendar UID.
  defp identifier(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp identifier(%{id: id}) when is_binary(id) and id != "", do: id
  defp identifier(%{"uid" => uid}) when is_binary(uid) and uid != "", do: uid
  defp identifier(%{uid: uid}) when is_binary(uid) and uid != "", do: uid
  defp identifier(_event), do: nil
end
