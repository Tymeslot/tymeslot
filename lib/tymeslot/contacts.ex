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

  Read-only, and nothing is stored: each search asks the servers, and only
  where their address books are is remembered for a while
  (`Tymeslot.Contacts.AddressBookCache`). A server that cannot be read
  contributes nothing to the answer rather than failing it.
  """

  require Logger

  alias Tymeslot.Contacts.{AddressBookCache, CardDAV}
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @type contact :: CardDAV.contact()

  # The CalDAV family keeps its address books beside its calendars, on the
  # host the connection already points at; iCloud does not.
  @not_beside_calendars ["apple"]

  @min_term_length 2
  @max_term_length 100
  @max_results 8
  @search_timeout 6_000

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
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, contacts} -> contacts
      {:exit, _reason} -> []
    end)
    |> rank(term)
  end

  defp search_source(integration, term) do
    client = Client.client_for_integration(integration)

    case address_books(integration, client) do
      {:ok, hrefs} ->
        Enum.flat_map(hrefs, &search_book(client, &1, term, integration.id))

      {:error, reason} ->
        Logger.info("No address books to suggest contacts from",
          integration_id: integration.id,
          reason: LogFormat.reason(reason)
        )

        []
    end
  end

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

  defp search_book(client, href, term, integration_id) do
    case CardDAV.search(client, href, term) do
      {:ok, contacts} ->
        contacts

      {:error, reason} ->
        Logger.info("Address book could not be searched",
          integration_id: integration_id,
          reason: LogFormat.reason(reason)
        )

        []
    end
  end

  # Servers differ in how they match, so the term is checked again here, and
  # the same address found in two address books is offered once, under the
  # first name given for it.
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
