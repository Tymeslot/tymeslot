defmodule Tymeslot.Contacts.ContactQueries do
  @moduledoc """
  Persistence for synced contacts (`Tymeslot.Contacts.ContactSchema`) and the
  address books they come from (`Tymeslot.Contacts.AddressBookSchema`).
  """

  import Ecto.Query

  alias Tymeslot.Contacts.{AddressBookSchema, ContactSchema}
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  @insert_chunk 1_000

  @doc """
  Every synced contact of `user_id`'s connections that currently suggest
  contacts, decrypted.
  """
  @spec list_for_user(pos_integer()) :: [%{name: String.t() | nil, email: String.t()}]
  def list_for_user(user_id) do
    Repo.all(
      from(c in ContactSchema,
        join: b in assoc(c, :address_book),
        join: i in CalendarIntegrationSchema,
        on: i.id == b.calendar_integration_id,
        where: i.user_id == ^user_id and i.use_for_contacts and i.is_active,
        order_by: [asc: i.id, asc: b.id, asc: c.id],
        select: %{name: c.name, email: c.email}
      )
    )
  end

  @doc "The address books synced for a connection."
  @spec list_books(pos_integer()) :: [AddressBookSchema.t()]
  def list_books(integration_id) do
    Repo.all(from(b in AddressBookSchema, where: b.calendar_integration_id == ^integration_id))
  end

  @doc """
  Replaces what is stored of the address book at `href` with `contacts`,
  under the token it was listed at, in one transaction.
  """
  @spec replace_book(pos_integer(), String.t(), String.t() | nil, [
          %{name: String.t() | nil, email: String.t()}
        ]) :: {:ok, AddressBookSchema.t()} | {:error, term()}
  def replace_book(integration_id, href, token, contacts) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.transaction(fn ->
      book =
        Repo.insert!(
          %AddressBookSchema{
            calendar_integration_id: integration_id,
            href: href,
            sync_token: token
          },
          on_conflict: [set: [sync_token: token, updated_at: now]],
          conflict_target: [:calendar_integration_id, :href],
          returning: true
        )

      Repo.delete_all(from(c in ContactSchema, where: c.calendar_contact_book_id == ^book.id))

      contacts
      |> Enum.map(&Map.merge(&1, %{calendar_contact_book_id: book.id, inserted_at: now}))
      |> Enum.chunk_every(@insert_chunk)
      |> Enum.each(&Repo.insert_all(ContactSchema, &1))

      book
    end)
  end

  @doc "Deletes a connection's address books other than those at `hrefs`, with their contacts."
  @spec delete_books_except(pos_integer(), [String.t()]) :: non_neg_integer()
  def delete_books_except(integration_id, hrefs) do
    {count, _} =
      Repo.delete_all(
        from(b in AddressBookSchema,
          where: b.calendar_integration_id == ^integration_id and b.href not in ^hrefs
        )
      )

    count
  end

  @doc "Deletes everything synced for a connection."
  @spec delete_for_integration(pos_integer()) :: non_neg_integer()
  def delete_for_integration(integration_id), do: delete_books_except(integration_id, [])

  @doc """
  Deletes what is synced for connections that no longer suggest contacts:
  turned off, or paused, while a sync was still writing.
  """
  @spec delete_for_inactive() :: non_neg_integer()
  def delete_for_inactive do
    {count, _} =
      Repo.delete_all(
        from(b in AddressBookSchema,
          join: i in CalendarIntegrationSchema,
          on: i.id == b.calendar_integration_id,
          where: not i.use_for_contacts or not i.is_active
        )
      )

    count
  end

  @doc "The ids of the connections that suggest contacts, of the providers given."
  @spec integration_ids_taking_part([String.t()]) :: [pos_integer()]
  def integration_ids_taking_part(providers) do
    Repo.all(
      from(i in CalendarIntegrationSchema,
        where: i.use_for_contacts and i.is_active and i.provider in ^providers,
        order_by: i.id,
        select: i.id
      )
    )
  end
end
