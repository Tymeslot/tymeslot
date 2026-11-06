defmodule Tymeslot.Contacts.AddressBookCache do
  @moduledoc """
  Remembers, per calendar connection, where its address books are, so a
  contact search does not walk the server's discovery chain on every
  keystroke, and which of them refuse to be searched. Only collection hrefs
  are held, never a contact.
  """
  use Tymeslot.Infrastructure.CacheStore,
    table_name: :contacts_address_book_cache,
    default_ttl: :timer.minutes(30),
    cleanup_interval: :timer.minutes(30)

  alias Tymeslot.Infrastructure.CacheStore

  @doc "The value stored under `key`, unless it has expired."
  @spec lookup(term()) :: {:ok, term()} | :miss
  def lookup(key), do: CacheStore.lookup(:contacts_address_book_cache, key)
end
