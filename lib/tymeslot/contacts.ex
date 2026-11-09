defmodule Tymeslot.Contacts do
  @moduledoc """
  Contact suggestions for the host: names and addresses from the address
  books of their calendar connections, offered wherever they type in whom to
  invite.

  A connection takes part once its owner turns on `use_for_contacts`, and
  only a connection whose server keeps address books beside its calendars
  can: the CalDAV family below, read over CardDAV (`Tymeslot.Contacts.CardDAV`).
  iCloud keeps its contacts on another host than its calendars, and Google
  and Microsoft speak no CardDAV, so none of those is offered.

  Read-only, and nothing is written anywhere. Each address book is listed
  once and searched here, so a contact is found by any part of their name or
  address whatever the server's own search supports; the names and
  addresses listed are held in memory for a few minutes, so typing a name
  does not list the book again on every keystroke, and dropped when the
  connection's credentials or contact setting change (`forget/1`). A book
  that cannot be listed is searched on the server instead. Where the books
  are is remembered too (`Tymeslot.Contacts.AddressBookCache`). A server
  that cannot be read contributes nothing to the answer rather than failing
  it.
  """

  require Logger

  alias Tymeslot.Contacts.{AddressBookCache, CardDAV}
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Shared.PathUtils

  @type contact :: CardDAV.contact()

  # The CalDAV family keeps its address books beside its calendars, on the
  # host the connection already points at; iCloud does not.
  @not_beside_calendars ["apple"]

  @min_term_length 2
  @max_term_length 100
  @max_results 8
  @search_timeout 10_000

  # How an address book that cannot be searched at all answers a search.
  @refusals [:server_error, :method_not_allowed, :forbidden, :not_found]

  # How long a book's listing answers searches before it is listed again,
  # and how long a book that could not be listed is searched on the server
  # before listing it is tried again.
  @listing_ttl :timer.minutes(5)
  @unlistable_ttl :timer.minutes(30)

  @doc "Whether a calendar connection of `provider` can offer contact suggestions."
  @spec supported_provider?(String.t() | atom() | nil) :: boolean()
  def supported_provider?(provider) when is_atom(provider) and not is_nil(provider),
    do: supported_provider?(Atom.to_string(provider))

  def supported_provider?(provider) when is_binary(provider),
    do:
      provider in ProviderConfig.caldav_based_provider_strings() and
        provider not in @not_beside_calendars

  def supported_provider?(_provider), do: false

  @doc "The shortest search term that is looked up."
  @spec min_term_length() :: pos_integer()
  def min_term_length, do: @min_term_length

  @doc """
  Up to #{@max_results} contacts of `user_id`'s whose name or address
  contains `term`, best first: a name or address starting with it before one
  merely containing it, then by name. One entry per address. A term shorter
  than #{@min_term_length} characters, or a host with no connection taking
  part, finds nothing.
  """
  @spec search(pos_integer(), String.t()) :: [contact()]
  def search(user_id, term) when is_integer(user_id) and is_binary(term) do
    term = String.trim(term)

    case sources(user_id) do
      [] ->
        []

      _sources when byte_size(term) > @max_term_length ->
        []

      sources ->
        if String.length(term) >= @min_term_length, do: search_all(sources, term), else: []
    end
  end

  def search(_user_id, _term), do: []

  @doc "Whether any of `user_id`'s calendar connections offers contact suggestions."
  @spec enabled?(pos_integer()) :: boolean()
  def enabled?(user_id) when is_integer(user_id), do: sources(user_id) != []

  @doc """
  Forgets where a connection's address books are, so the next search finds
  them again: called when its credentials or its contact setting change.
  """
  @spec forget(pos_integer()) :: :ok
  def forget(integration_id) do
    AddressBookCache.invalidate({:address_books, integration_id})
    AddressBookCache.invalidate_pattern({:unsearchable, integration_id, :_})
    AddressBookCache.invalidate_pattern({:contacts, integration_id, :_})
    AddressBookCache.invalidate_pattern({:unlistable, integration_id, :_})
    :ok
  end

  defp sources(user_id) do
    user_id
    |> Management.list_active_calendar_integrations()
    |> Enum.filter(&(&1.use_for_contacts and supported_provider?(&1.provider)))
  end

  defp search_all(sources, term) do
    sources
    |> Tasks.async_stream(&search_source(&1, term),
      timeout: @search_timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, contacts} -> contacts
      {:exit, _reason} -> []
    end)
    |> rank(term)
  end

  defp search_source(integration, term) do
    client = integration |> dav_root() |> Client.client_for_integration()

    case address_books(integration, client) do
      {:ok, hrefs} ->
        hrefs
        |> Enum.reject(&unsearchable?(integration.id, &1))
        |> Tasks.async_stream(&search_book(client, &1, term, integration.id),
          timeout: @search_timeout,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.flat_map(fn
          {:ok, contacts} -> contacts
          {:exit, _reason} -> []
        end)

      {:error, reason} ->
        Logger.info("No address books to suggest contacts from",
          integration_id: integration.id,
          reason: LogFormat.reason(reason)
        )

        []
    end
  end

  # A Nextcloud connection may be stored with the bare server address, which
  # its calendars complete with the DAV endpoint when they are read
  # (`Nextcloud.Provider`); the address books live under the same endpoint,
  # so they are looked for there too.
  defp dav_root(%{provider: "nextcloud", base_url: base_url} = integration)
       when is_binary(base_url) do
    %{
      integration
      | base_url:
          PathUtils.normalize_url(base_url, provider: :nextcloud, ensure_trailing_slash: false)
    }
  end

  defp dav_root(integration), do: integration

  # A failed discovery is not remembered, so a server that was down is
  # asked again on the next search rather than for the rest of the TTL.
  defp address_books(integration, client) do
    AddressBookCache.get_or_compute(
      {:address_books, integration.id},
      fn -> CardDAV.address_books(client) end,
      :timer.minutes(30),
      cache_errors: false
    )
  end

  # The book's listing when it can be had, which `rank/2` then filters by the
  # term; otherwise the server's own search.
  defp search_book(client, href, term, integration_id) do
    if unlistable?(integration_id, href) do
      server_search(client, href, term, integration_id)
    else
      case listing(client, href, integration_id) do
        {:ok, contacts} ->
          contacts

        {:error, reason} ->
          Logger.info("Address book could not be listed, searching it on the server",
            integration_id: integration_id,
            reason: LogFormat.reason(reason)
          )

          AddressBookCache.put({:unlistable, integration_id, href}, true, @unlistable_ttl)
          server_search(client, href, term, integration_id)
      end
    end
  end

  defp listing(client, href, integration_id) do
    AddressBookCache.get_or_compute(
      {:contacts, integration_id, href},
      fn -> CardDAV.contacts(client, href) end,
      @listing_ttl,
      cache_errors: false
    )
  end

  defp unlistable?(integration_id, href),
    do: match?({:ok, true}, AddressBookCache.lookup({:unlistable, integration_id, href}))

  defp server_search(client, href, term, integration_id) do
    case CardDAV.search(client, href, term) do
      {:ok, contacts} ->
        contacts

      {:error, reason} ->
        Logger.info("Address book could not be searched",
          integration_id: integration_id,
          reason: LogFormat.reason(reason)
        )

        if reason in @refusals, do: mark_unsearchable(integration_id, href)
        []
    end
  end

  # Some address books list fine but refuse every search: SOGo's global
  # address lists (mailcow's per-domain ones among them) answer any
  # addressbook-query with a server error. Such a book is left out of the
  # searches for a while instead of being asked again on every keystroke.
  defp unsearchable?(integration_id, href) do
    match?({:ok, true}, AddressBookCache.lookup({:unsearchable, integration_id, href}))
  end

  defp mark_unsearchable(integration_id, href),
    do: AddressBookCache.put({:unsearchable, integration_id, href}, true, :timer.minutes(30))

  # Servers differ in how they match, so the term is checked again here, and
  # the same address found in two address books is offered once, under the
  # name the first of them gives it: connections and their books are searched
  # in parallel but answer in their own order (`ordered: true`), so which name
  # that is does not depend on which server happened to answer first.
  defp rank(contacts, term) do
    needle = String.downcase(term)

    contacts
    |> Enum.filter(&matches?(&1, needle))
    |> Enum.uniq_by(& &1.email)
    |> Enum.sort_by(&{not prefix?(&1, needle), String.downcase(&1.name || &1.email)})
    |> Enum.take(@max_results)
  end

  defp matches?(contact, needle),
    do: Enum.any?(fields(contact), &String.contains?(&1, needle))

  defp prefix?(contact, needle),
    do: Enum.any?(fields(contact), &String.starts_with?(&1, needle))

  defp fields(%{name: name, email: email}),
    do: Enum.map([name || "", email], &String.downcase/1)
end
