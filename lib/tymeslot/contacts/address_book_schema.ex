defmodule Tymeslot.Contacts.AddressBookSchema do
  @moduledoc """
  An address book of a calendar connection that suggests contacts, as last
  synced (`Tymeslot.Contacts.Sync`): where it is on the server, and the token
  the server versioned its contents by then, so an unchanged book is not
  listed again.
  """

  use Ecto.Schema

  alias Tymeslot.Contacts.ContactSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          calendar_integration_id: pos_integer() | nil,
          href: String.t() | nil,
          sync_token: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_contact_books" do
    field(:href, :string)
    field(:sync_token, :string)

    belongs_to(:calendar_integration, CalendarIntegrationSchema)
    has_many(:contacts, ContactSchema, foreign_key: :calendar_contact_book_id)

    timestamps(type: :utc_datetime)
  end
end
