defmodule Tymeslot.Contacts.ContactSchema do
  @moduledoc """
  A name and address synced from an address book (`Tymeslot.Contacts.Sync`),
  one row per address. Both are someone else's personal data, so both are
  encrypted at rest, as the connection's credentials are.
  """

  use Ecto.Schema

  alias Tymeslot.Contacts.AddressBookSchema
  alias Tymeslot.Security.EncryptedString

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          calendar_contact_book_id: pos_integer() | nil,
          name: String.t() | nil,
          email: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "calendar_contacts" do
    field(:name, EncryptedString, source: :name_encrypted, redact: true)
    field(:email, EncryptedString, source: :email_encrypted, redact: true)

    belongs_to(:address_book, AddressBookSchema, foreign_key: :calendar_contact_book_id)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
