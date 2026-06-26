defmodule Tymeslot.MeetingTypes.MeetingTypeAttachment do
  @moduledoc """
  Embedded schema for a single host-uploaded file attached to a meeting type
  (e.g. an agenda or brief). Every booking of the type surfaces these files in
  the calendar event (`ATTACH`) and the confirmation email.

  The file itself lives on disk under the uploads directory; this record only
  carries the metadata needed to build the public download URL and the
  iCalendar `ATTACH;FMTTYPE` line. `stored_path` is the path relative to the
  uploads root (served under `/uploads/...`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ecto.UUID

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :id, :string
    field :filename, :string
    field :stored_path, :string
    field :content_type, :string
    field :byte_size, :integer
  end

  @doc "Builds a changeset, auto-filling `id` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:id, :filename, :stored_path, :content_type, :byte_size])
    |> ensure_id()
    |> validate_required([:filename, :stored_path])
  end

  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, UUID.generate())
      _present -> changeset
    end
  end
end
