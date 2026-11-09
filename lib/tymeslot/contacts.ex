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

  The books are synced into Tymeslot (`Tymeslot.Contacts.Sync`), as its
  calendars are: right away when suggestions are turned on, then by
  `Tymeslot.Workers.ContactsSyncSweepWorker` every 15 minutes. A search
  reads only the database, so it answers at once whatever the server, and
  matches any part of a name or address whatever the server's own search
  would have. Names and addresses are encrypted at rest; turning
  suggestions off deletes them, and disconnecting the calendar or deleting
  the account takes them along.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  alias Tymeslot.Contacts.{ContactQueries, ContactSchema}
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Shared.PathUtils
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Workers.ContactsSyncWorker

  @type contact :: %{name: String.t() | nil, email: String.t()}

  # The CalDAV family keeps its address books beside its calendars, on the
  # host the connection already points at; iCloud does not.
  @not_beside_calendars ["apple"]

  @min_term_length 2
  @max_term_length 100
  @max_results 8

  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage,
    do: {ContactSchema.__schema__(:source), EncryptedString.columns(ContactSchema)}

  @doc "Whether a calendar connection of `provider` can offer contact suggestions."
  @spec supported_provider?(String.t() | atom() | nil) :: boolean()
  def supported_provider?(provider) when is_atom(provider) and not is_nil(provider),
    do: supported_provider?(Atom.to_string(provider))

  def supported_provider?(provider) when is_binary(provider),
    do: provider in supported_providers()

  def supported_provider?(_provider), do: false

  @doc "The providers whose connections can offer contact suggestions."
  @spec supported_providers() :: [String.t()]
  def supported_providers,
    do: ProviderConfig.caldav_based_provider_strings() -- @not_beside_calendars

  @doc "The shortest search term that is looked up."
  @spec min_term_length() :: pos_integer()
  def min_term_length, do: @min_term_length

  @doc """
  Up to #{@max_results} of `user_id`'s synced contacts whose name or address
  contains `term`, ignoring case, best first: a name, a word of it, or an
  address starting with it before one merely containing it, then by name.
  One entry per address, under the name its first connection gives it. A
  term shorter than #{@min_term_length} characters finds nothing.
  """
  @spec search(pos_integer(), String.t()) :: [contact()]
  def search(user_id, term) when is_integer(user_id) and is_binary(term) do
    term = String.trim(term)

    if String.length(term) >= @min_term_length and byte_size(term) <= @max_term_length do
      user_id |> ContactQueries.list_for_user() |> rank(term)
    else
      []
    end
  end

  def search(_user_id, _term), do: []

  @doc """
  Syncs a connection's address books now, in the background: called when
  suggestions are turned on, so they are there before the next sweep.
  """
  @spec sync_soon(pos_integer()) :: :ok | {:error, term()}
  def sync_soon(integration_id) do
    case integration_id |> ContactsSyncWorker.job() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Deletes everything synced from a connection's address books."
  @spec drop(pos_integer()) :: :ok
  def drop(integration_id) do
    ContactQueries.delete_for_integration(integration_id)
    :ok
  end

  @doc """
  The connection as its address books are reached. A Nextcloud connection
  may be stored with the bare server address, which its calendars complete
  with the DAV endpoint when they are read (`Nextcloud.Provider`); its
  address books live under the same endpoint.
  """
  @spec dav_root(map()) :: map()
  def dav_root(%{provider: "nextcloud", base_url: base_url} = integration)
      when is_binary(base_url) do
    %{
      integration
      | base_url:
          PathUtils.normalize_url(base_url, provider: :nextcloud, ensure_trailing_slash: false)
    }
  end

  def dav_root(integration), do: integration

  defp rank(contacts, term) do
    needle = String.downcase(term)

    contacts
    |> Enum.filter(&matches?(&1, needle))
    |> Enum.uniq_by(& &1.email)
    |> Enum.sort_by(&{not leading?(&1, needle), String.downcase(&1.name || &1.email)})
    |> Enum.take(@max_results)
  end

  defp matches?(contact, needle),
    do: Enum.any?(fields(contact), &String.contains?(&1, needle))

  # A field, or a word of it, starting with the term: "claudia" leads for
  # "Miller, Claudia" as it does for "Claudia Miller".
  defp leading?(contact, needle) do
    contact
    |> fields()
    |> Enum.flat_map(&[&1 | String.split(&1, [" ", ",", "-", "."], trim: true)])
    |> Enum.any?(&String.starts_with?(&1, needle))
  end

  defp fields(%{name: name, email: email}),
    do: Enum.map([name || "", email], &String.downcase/1)
end
