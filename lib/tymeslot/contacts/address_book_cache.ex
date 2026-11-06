defmodule Tymeslot.Contacts.AddressBookCache do
  @moduledoc """
  Remembers, per calendar connection, where its address books are, so a
  contact search does not walk the server's discovery chain on every
  keystroke. Only the collection hrefs are held, never a contact.
  """
  use Tymeslot.Infrastructure.CacheStore,
    table_name: :contacts_address_book_cache,
    default_ttl: :timer.minutes(30),
    cleanup_interval: :timer.minutes(30)
end
