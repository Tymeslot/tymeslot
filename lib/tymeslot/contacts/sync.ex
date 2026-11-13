defmodule Tymeslot.Contacts.Sync do
  @moduledoc """
  Copies the names and addresses in a calendar connection's address books
  into Tymeslot (`Tymeslot.Contacts.ContactQueries`), so suggestions are
  searched in the database while the host types.

  Each run finds the books (`Tymeslot.Contacts.CardDAV.address_books/1`) and
  lists those whose token changed since the last run, or that have none;
  a book that is gone from the server is dropped. A book that cannot be
  listed keeps what an earlier run stored, so a server that is briefly down
  does not empty the suggestions, and is tried again on the next run.
  """

  require Logger

  alias Tymeslot.Contacts
  alias Tymeslot.Contacts.{CardDAV, ContactQueries}
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Security.FieldValidators.EmailValidator

  @max_name_length 200

  @type outcome :: %{
          synced: non_neg_integer(),
          unchanged: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc "Syncs the address books of `integration`, whose credentials are decrypted."
  @spec run(map()) :: {:ok, outcome()} | {:error, term()}
  def run(integration) do
    client = integration |> Contacts.dav_root() |> Client.client_for_integration()

    with {:ok, books} <- CardDAV.address_books(client) do
      ContactQueries.delete_books_except(integration.id, Enum.map(books, & &1.href))
      known = Map.new(ContactQueries.list_books(integration.id), &{&1.href, &1.sync_token})

      outcome =
        books
        |> Enum.map(&sync_book(client, integration.id, &1, known))
        |> Enum.frequencies()

      {:ok,
       %{
         synced: Map.get(outcome, :synced, 0),
         unchanged: Map.get(outcome, :unchanged, 0),
         failed: Map.get(outcome, :failed, 0)
       }}
    end
  end

  defp sync_book(client, integration_id, %{href: href, token: token}, known) do
    if is_binary(token) and Map.get(known, href) == token do
      :unchanged
    else
      list_book(client, integration_id, href, token)
    end
  end

  defp list_book(client, integration_id, href, token) do
    with {:ok, contacts} <- CardDAV.contacts(client, href),
         {:ok, _book} <-
           ContactQueries.replace_book(integration_id, href, token, distinct(contacts)) do
      :synced
    else
      {:error, reason} ->
        # Some books are listed but refuse to be read: SOGo's global address
        # lists, mailcow's per-domain ones among them, answer with a server
        # error.
        Logger.info("Address book could not be synced",
          integration_id: integration_id,
          reason: LogFormat.reason(reason)
        )

        :failed
    end
  end

  # One entry per address within a book, under the first name it is given;
  # a card's EMAIL that is not an address anyone could be invited at (a
  # placeholder, a typo) is left out.
  defp distinct(contacts) do
    contacts
    |> Enum.map(&%{name: name(&1.name), email: &1.email |> String.trim() |> String.downcase()})
    |> Enum.filter(&(EmailValidator.validate(&1.email) == :ok))
    |> Enum.uniq_by(& &1.email)
  end

  defp name(nil), do: nil

  defp name(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_name_length)
    end
  end
end
